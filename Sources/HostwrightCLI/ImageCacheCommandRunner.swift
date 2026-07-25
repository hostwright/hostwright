import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

struct ImageCacheCommandRunner {
    let options: ImageCLIOptions
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        try hostwrightWaitForAsync {
            try await runAsync()
        }
    }

    private func runAsync() async throws -> CLIRunResult {
        let stateConfiguration =
            try hostwrightStateStoreConfiguration(
                explicitPath: options.stateDatabasePath,
                environment: environment
            )
        let coordinator = ImageLifecycleCoordinator(
            environment: environment,
            stateStoreConfiguration: stateConfiguration
        )
        let operation: RuntimeImageLifecycleOperation
        if case .prune = options.action {
            operation = .prune
        } else {
            operation = .inspect
        }
        let selected = try await coordinator.selectProvider(
            operation: operation,
            selection: options.runtimeProvider
        )
        guard selected.capability.status(for: .inspect).state ==
                .available,
              selected.capability.status(for: .inspect).reason ==
                .implemented else {
            throw HostwrightDiagnostic(
                code: .imageUnavailable,
                message:
                    "Image cache accounting requires structured provider inspection."
            )
        }
        let store = SQLiteStateStore(
            configuration: stateConfiguration
        )
        try store.migrate()
        let observation = try await observe(
            selected: selected,
            store: store
        )

        switch options.action {
        case .cacheStatus(let maximumBytes):
            return try renderStatus(
                observation,
                maximumBytes: maximumBytes
            )
        case .pin(let reference):
            return try renderPin(
                reference: reference,
                pinPolicy: .operatorManaged,
                observation: observation,
                store: store
            )
        case .unpin(let reference):
            return try renderPin(
                reference: reference,
                pinPolicy: .unpinned,
                observation: observation,
                store: store
            )
        case .prune(let cliPolicy):
            return try await runPrune(
                cliPolicy,
                observation: observation,
                selected: selected,
                coordinator: coordinator
            )
        case .inspect, .pull, .push, .tag, .load, .save, .build,
             .delete:
            throw HostwrightDiagnostic(
                code: .imageInvalid,
                message:
                    "Image cache runner received a non-cache operation."
            )
        }
    }

    private func observe(
        selected: SelectedImageProvider,
        store: SQLiteStateStore
    ) async throws -> ImageCacheObservation {
        let timestamp = imageLifecycleTimestamp()
        let inventory = try await selected.provider.inventory()
        let projection = try store.imageOwnership.load()
        var digestByReference: [String: String] = [:]
        var referencesByDigest: [String: Set<String>] = [:]
        for image in inventory.images {
            for reference in image.references {
                if let existing = digestByReference[reference],
                   existing != image.descriptorDigest {
                    throw HostwrightDiagnostic(
                        code: .imageConflict,
                        message:
                            "Runtime inventory mapped one reference to conflicting content."
                    )
                }
                digestByReference[reference] =
                    image.descriptorDigest
                referencesByDigest[
                    image.descriptorDigest,
                    default: []
                ].insert(reference)
            }
        }

        let providerOwnership = projection.records.filter {
            $0.providerID == selected.providerID.rawValue
        }
        guard providerOwnership.count <=
                ImageCacheLimits.maximumRecords else {
            throw HostwrightDiagnostic(
                code: .imageUnavailable,
                message:
                    "Owned image cache inventory exceeds its bounded accounting limit."
            )
        }
        var ownedByDigest: [String: [ImageOwnershipRecord]] = [:]
        var staleOwnership: [ImageOwnershipRecord] = []
        for ownership in providerOwnership {
            guard let currentDigest =
                    digestByReference[ownership.reference] else {
                staleOwnership.append(ownership)
                continue
            }
            guard currentDigest == ownership.digest else {
                throw HostwrightDiagnostic(
                    code: .imageConflict,
                    message:
                        "Runtime image reference conflicts with Hostwright ownership evidence."
                )
            }
            ownedByDigest[ownership.digest, default: []]
                .append(ownership)
        }

        let inspectReferences = ownedByDigest.values.compactMap {
            $0.map(\.reference).sorted().first
        }.sorted()
        var inspectedByDigest: [String: RuntimeImageRecord] = [:]
        for start in stride(
            from: 0,
            to: inspectReferences.count,
            by:
                RuntimeImageLifecycleLimits
                    .maximumSourceReferencesPerRequest
        ) {
            let end = min(
                start +
                    RuntimeImageLifecycleLimits
                        .maximumSourceReferencesPerRequest,
                inspectReferences.count
            )
            let references = Array(
                inspectReferences[start..<end]
            )
            let request = try RuntimeImageLifecycleRequest(
                operation: .inspect,
                operationID: UUID().uuidString.lowercased(),
                idempotencyKey: sha256(
                    [
                        "image-cache-observation",
                        selected.providerID.rawValue,
                        references.joined(separator: ",")
                    ].joined(separator: "\u{1f}")
                ),
                capabilitySHA256:
                    selected.capability.capabilitySHA256,
                sourceReferences: references
            )
            let result =
                try await selected.provider.performImageOperation(
                    request,
                    confirmation: nil,
                    progress: { _ in }
                )
            for image in result.images {
                guard inspectedByDigest[image.digest] == nil else {
                    throw HostwrightDiagnostic(
                        code: .imageConflict,
                        message:
                            "Runtime inspection returned duplicate content records."
                    )
                }
                inspectedByDigest[image.digest] = image
            }
        }

        let initial = try store.contentCache.snapshot(
            providerScope: selected.providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        let initialContent = Dictionary(
            uniqueKeysWithValues: initial.contents.map {
                ($0.digest, $0)
            }
        )
        let initialReferences = Dictionary(
            uniqueKeysWithValues: initial.references.map {
                ($0.reference, $0)
            }
        )
        let policyPinnedDigests = Set(
            try store.imageDigestLocks.loadCurrentDesired(
                runtimeProvider: selected.providerID.rawValue,
                maximumRecords:
                    ImageCacheLimits.maximumRecords
            ).map(\.lock.descriptorDigest)
        )
        for digest in ownedByDigest.keys.sorted() {
            guard let inspected = inspectedByDigest[digest],
                  inspected.digest == digest else {
                throw HostwrightDiagnostic(
                    code: .imageUnavailable,
                    message:
                        "Runtime inspection omitted exact owned cache content."
                )
            }
            let existing = initialContent[digest]
            let pinPolicy: ContentCachePinPolicy
            if existing?.pinPolicy == .operatorManaged {
                pinPolicy = .operatorManaged
            } else if policyPinnedDigests.contains(digest) {
                pinPolicy = .policyManaged
            } else {
                pinPolicy = .unpinned
            }
            try store.contentCache.upsert(
                ContentCacheRecord(
                    providerScope:
                        selected.providerID.rawValue,
                    digest: digest,
                    kind: .runtimeImage,
                    sizeBytes: inspected.sizeBytes,
                    pinPolicy: pinPolicy,
                    createdAt:
                        existing?.createdAt ?? timestamp,
                    observedAt: timestamp,
                    lastUsedAt:
                        existing?.lastUsedAt ?? timestamp
                )
            )
            for ownership in
                ownedByDigest[digest, default: []].sorted(
                    by: { $0.reference < $1.reference }
                ) {
                try saveReference(
                    ownership,
                    existing:
                        initialReferences[ownership.reference],
                    observedAt: timestamp,
                    store: store
                )
            }
        }

        let snapshot = try store.contentCache.snapshot(
            providerScope: selected.providerID.rawValue,
            currentTimestamp: timestamp,
            limit: ImageCacheLimits.maximumRecords
        )
        let cacheByDigest = Dictionary(
            uniqueKeysWithValues: snapshot.contents.map {
                ($0.digest, $0)
            }
        )
        let activeLeaseDigests = Set(
            snapshot.activeLeases.map(\.digest)
        )
        let liveDigests = Set(
            inventory.containers.compactMap(\.imageID)
        )
        let liveReferences = Set(
            inventory.containers.map(\.imageReference)
        )
        let cacheReferenceByReference = Dictionary(
            uniqueKeysWithValues: snapshot.references.map {
                ($0.reference, $0)
            }
        )
        var prunableStaleOwnedReferences: [String] = []
        for ownership in staleOwnership.sorted(
            by: { $0.reference < $1.reference }
        ) {
            guard let ownershipOperationID =
                    ownership.ownershipOperationID,
                  let ownershipProofSHA256 =
                    ownership.ownershipProofSHA256 else {
                continue
            }
            if let cached =
                cacheReferenceByReference[ownership.reference] {
                guard cached.digest == ownership.digest,
                      cached.ownershipOperationID ==
                        ownershipOperationID,
                      cached.ownershipProofSHA256 ==
                        ownershipProofSHA256 else {
                    throw HostwrightDiagnostic(
                        code: .imageConflict,
                        message:
                            "Stale image cache ownership evidence is inconsistent."
                    )
                }
            }
            let accounting = cacheByDigest[ownership.digest]
            guard accounting?.pinPolicy != .operatorManaged,
                  accounting?.pinPolicy != .policyManaged,
                  !policyPinnedDigests.contains(ownership.digest),
                  !activeLeaseDigests.contains(ownership.digest),
                  !liveDigests.contains(ownership.digest),
                  !liveReferences.contains(ownership.reference) else {
                continue
            }
            prunableStaleOwnedReferences.append(
                ownership.reference
            )
        }
        let content = try ownedByDigest.keys.sorted().map {
            digest -> ImageCacheObservedContent in
            guard let accounting = cacheByDigest[digest] else {
                throw HostwrightDiagnostic(
                    code: .imageUnavailable,
                    message:
                        "Exact cache accounting disappeared during observation."
                )
            }
            let references = Array(
                referencesByDigest[digest, default: []]
            ).sorted()
            return ImageCacheObservedContent(
                providerID: selected.providerID.rawValue,
                digest: digest,
                sizeBytes: accounting.sizeBytes,
                references: references,
                ownedReferences:
                    ownedByDigest[digest, default: []]
                        .map(\.reference),
                liveReferences: references.filter {
                    liveReferences.contains($0)
                },
                liveDigest: liveDigests.contains(digest),
                pinned: accounting.pinPolicy != .unpinned,
                leased: activeLeaseDigests.contains(digest),
                lastUsedAt: accounting.lastUsedAt
            )
        }
        return ImageCacheObservation(
            providerID: selected.providerID,
            capabilitySHA256:
                selected.capability.capabilitySHA256,
            inventorySHA256: inventory.semanticSHA256,
            evaluatedAt: timestamp,
            content: content,
            staleOwnedReferences:
                staleOwnership.map(\.reference).sorted(),
            prunableStaleOwnedReferences:
                prunableStaleOwnedReferences,
            activeLeases: snapshot.activeLeases,
            policyPinnedDigests: policyPinnedDigests
        )
    }

    private func runPrune(
        _ cliPolicy: ImageCachePruneCLIOptions,
        observation: ImageCacheObservation,
        selected: SelectedImageProvider,
        coordinator: ImageLifecycleCoordinator
    ) async throws -> CLIRunResult {
        let policy = try ImageCachePrunePolicyV1(
            maximumBytes: cliPolicy.maximumBytes,
            targetBytes: cliPolicy.targetBytes,
            retentionSeconds: cliPolicy.retentionSeconds,
            maximumDeletions: cliPolicy.maximumDeletions
        )
        let plan = try ImageCachePrunePlanner.plan(
            providerID: observation.providerID.rawValue,
            capabilitySHA256:
                observation.capabilitySHA256,
            observationSHA256:
                observation.inventorySHA256,
            content: observation.content,
            staleOwnedReferences:
                observation.prunableStaleOwnedReferences,
            policy: policy,
            evaluatedAt: observation.evaluatedAt
        )
        if let confirmation =
            cliPolicy.confirmationPlanSHA256 {
            guard confirmation == plan.planSHA256 else {
                throw HostwrightDiagnostic(
                    code: .imageDenied,
                    message:
                        "Image prune confirmation does not match the current exact cache plan."
                )
            }
        }
        if cliPolicy.dryRun ||
            (plan.candidates.isEmpty &&
                plan.staleOwnedReferences.isEmpty) {
            return renderPrune(plan: plan, execution: nil)
        }

        let exactReferences = Array(
            Set(plan.candidates.flatMap(\.references) +
                plan.staleOwnedReferences)
        ).sorted()
        let execution = try await coordinator.executeAsyncForCache(
            input: ImageLifecycleInput(
                operation: .prune,
                exactPruneReferences: exactReferences,
                expectedAbsentPruneReferences:
                    plan.staleOwnedReferences,
                confirmedCachePlanSHA256: plan.planSHA256,
                expectedProviderID: observation.providerID,
                expectedCapabilitySHA256:
                    observation.capabilitySHA256
            ),
            selection: options.runtimeProvider
        )
        return renderPrune(plan: plan, execution: execution)
    }

    private func renderStatus(
        _ observation: ImageCacheObservation,
        maximumBytes: Int64?
    ) throws -> CLIRunResult {
        let totalBytes = try observation.content.reduce(Int64(0)) {
            partial, item in
            guard item.sizeBytes <= Int64.max - partial else {
                throw HostwrightDiagnostic(
                    code: .imageUnavailable,
                    message:
                        "Image cache byte accounting exceeded its supported bound."
                )
            }
            return partial + item.sizeBytes
        }
        let pressure: ImageCachePressureState
        if let maximumBytes {
            pressure = totalBytes > maximumBytes
                ? .exceeded
                : .normal
        } else {
            pressure = .notConfigured
        }
        let report = ImageCacheStatusReportV1(
            providerID: observation.providerID.rawValue,
            capabilitySHA256:
                observation.capabilitySHA256,
            observationSHA256:
                observation.inventorySHA256,
            observedAt: observation.evaluatedAt,
            pressure: pressure,
            maximumBytes: maximumBytes,
            totalBytes: totalBytes,
            content: observation.content.map {
                ImageCacheStatusContentV1(
                    digest: $0.digest,
                    sizeBytes: $0.sizeBytes,
                    references: $0.references,
                    ownedReferences: $0.ownedReferences,
                    pinned: $0.pinned,
                    leased: $0.leased,
                    lastUsedAt: $0.lastUsedAt
                )
            },
            staleOwnedReferences:
                observation.staleOwnedReferences,
            prunableStaleOwnedReferences:
                observation.prunableStaleOwnedReferences,
            activeLeaseCount:
                observation.activeLeases.count
        )
        if options.output == .json {
            return CLIRunResult(
                standardOutput: CLIJSON.codable(report)
            )
        }
        return CLIRunResult(
            standardOutput:
                "image cache \(pressure.rawValue)\n" +
                "provider: \(report.providerID)\n" +
                "content: \(report.content.count)\n" +
                "stale owned references: \(report.staleOwnedReferences.count)\n" +
                "prunable stale references: \(report.prunableStaleOwnedReferences.count)\n" +
                "bytes: \(report.totalBytes)\n" +
                "active leases: \(report.activeLeaseCount)\n"
        )
    }

    private func renderPin(
        reference: String,
        pinPolicy: ContentCachePinPolicy,
        observation: ImageCacheObservation,
        store: SQLiteStateStore
    ) throws -> CLIRunResult {
        guard let content = observation.content.first(where: {
            $0.ownedReferences.contains(reference)
        }) else {
            throw HostwrightDiagnostic(
                code: .imageConflict,
                message:
                    "Image cache pin requires one exact Hostwright-owned reference."
            )
        }
        let effectivePinPolicy: ContentCachePinPolicy =
            pinPolicy == .unpinned &&
                observation.policyPinnedDigests.contains(
                    content.digest
                )
            ? .policyManaged
            : pinPolicy
        guard try store.contentCache.setPinPolicy(
            providerScope: observation.providerID.rawValue,
            digest: content.digest,
            pinPolicy: effectivePinPolicy,
            observedAt: imageLifecycleTimestamp()
        ) else {
            throw HostwrightDiagnostic(
                code: .imageConflict,
                message:
                    "Image cache content changed before pin policy was recorded."
            )
        }
        let report = ImageCachePinReportV1(
            providerID: observation.providerID.rawValue,
            reference: reference,
            digest: content.digest,
            pinPolicy: effectivePinPolicy.rawValue,
            observedAt: imageLifecycleTimestamp()
        )
        if options.output == .json {
            return CLIRunResult(
                standardOutput: CLIJSON.codable(report)
            )
        }
        return CLIRunResult(
            standardOutput:
                "image cache \(effectivePinPolicy.rawValue)\n" +
                "reference: \(reference)\n" +
                "digest: \(content.digest)\n"
        )
    }

    private func renderPrune(
        plan: ImageCachePrunePlanV1,
        execution: ImageLifecycleExecution?
    ) -> CLIRunResult {
        let disposition =
            execution?.result.disposition.rawValue ?? "planned"
        let report = ImageCachePruneReportV1(
            plan: plan,
            disposition: disposition,
            operationID: execution?.result.operationID,
            deletedReferences:
                execution?.deletedReferences ?? [],
            deletedDigests:
                execution?.result.deletedDigests ?? []
        )
        if options.output == .json {
            return CLIRunResult(
                standardOutput: CLIJSON.codable(report)
            )
        }
        return CLIRunResult(
            standardOutput:
                "image cache prune \(report.disposition)\n" +
                "plan: \(plan.planSHA256)\n" +
                "pressure: \(plan.pressure.rawValue)\n" +
                "bytes: \(plan.totalBytes) -> \(plan.projectedBytes)\n" +
                "candidates: \(plan.candidates.count)\n" +
                "deleted: \(report.deletedReferences.count)\n"
        )
    }

    private func saveReference(
        _ ownership: ImageOwnershipRecord,
        existing: ContentCacheReferenceRecord?,
        observedAt: String,
        store: SQLiteStateStore
    ) throws {
        guard let operationID =
                ownership.ownershipOperationID,
              let proof = ownership.ownershipProofSHA256 else {
            throw HostwrightDiagnostic(
                code: .imageConflict,
                message:
                    "Image cache reference lacks exact ownership provenance."
            )
        }
        if let existing {
            guard existing.digest == ownership.digest,
                  existing.ownershipOperationID == operationID,
                  existing.ownershipProofSHA256 == proof else {
                throw HostwrightDiagnostic(
                    code: .imageConflict,
                    message:
                        "Image cache reference ownership changed during observation."
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
                ownershipOperationID: operationID,
                ownershipProofSHA256: proof,
                createdAt: existing?.createdAt ?? observedAt,
                observedAt: observedAt
            )
        )
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct ImageCacheObservation {
    let providerID: RuntimeProviderID
    let capabilitySHA256: String
    let inventorySHA256: String
    let evaluatedAt: String
    let content: [ImageCacheObservedContent]
    let staleOwnedReferences: [String]
    let prunableStaleOwnedReferences: [String]
    let activeLeases: [ContentCacheLeaseRecord]
    let policyPinnedDigests: Set<String>
}

private struct ImageCacheStatusContentV1: Codable {
    let digest: String
    let sizeBytes: Int64
    let references: [String]
    let ownedReferences: [String]
    let pinned: Bool
    let leased: Bool
    let lastUsedAt: String
}

private struct ImageCacheStatusReportV1: Encodable {
    let schemaVersion = 1
    let kind = "imageCacheStatus"
    let providerID: String
    let capabilitySHA256: String
    let observationSHA256: String
    let observedAt: String
    let pressure: ImageCachePressureState
    let maximumBytes: Int64?
    let totalBytes: Int64
    let content: [ImageCacheStatusContentV1]
    let staleOwnedReferences: [String]
    let prunableStaleOwnedReferences: [String]
    let activeLeaseCount: Int
}

private struct ImageCachePinReportV1: Encodable {
    let schemaVersion = 1
    let kind = "imageCachePin"
    let providerID: String
    let reference: String
    let digest: String
    let pinPolicy: String
    let observedAt: String
}

private struct ImageCachePruneReportV1: Encodable {
    let schemaVersion = 1
    let kind = "imageCachePrune"
    let plan: ImageCachePrunePlanV1
    let disposition: String
    let operationID: String?
    let deletedReferences: [String]
    let deletedDigests: [String]
}
