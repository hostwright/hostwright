import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class ImageCacheCommandRunnerTests: XCTestCase {
    func testDryRunThenExactConfirmationDeletesOnlyManagedContent()
        async throws
    {
        try await withHarness { harness in
            try harness.pull("registry.example/app:old")

            let preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            let plan = try XCTUnwrap(preview["plan"] as? [String: Any])
            let planSHA256 = try XCTUnwrap(
                plan["planSHA256"] as? String
            )
            XCTAssertEqual(
                (plan["candidates"] as? [[String: Any]])?.count,
                1
            )
            let presentBefore = await harness.provider.contains(
                "registry.example/app:old"
            )
            XCTAssertTrue(presentBefore)

            let execution = try harness.runJSON([
                "image", "prune",
                "--confirm-plan", planSHA256,
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            XCTAssertEqual(
                execution["disposition"] as? String,
                "succeeded"
            )
            let presentAfter = await harness.provider.contains(
                "registry.example/app:old"
            )
            XCTAssertFalse(presentAfter)

            let store = SQLiteStateStore(path: harness.statePath)
            XCTAssertTrue(try store.imageOwnership.load().records.isEmpty)
            let cache = try store.contentCache.snapshot(
                providerScope:
                    RuntimeProviderID.appleContainerCLI.rawValue,
                currentTimestamp: "2026-07-25T12:00:00Z"
            )
            XCTAssertTrue(cache.contents.isEmpty)
            XCTAssertTrue(cache.references.isEmpty)
            XCTAssertTrue(cache.activeLeases.isEmpty)
            let pruneGroup = try XCTUnwrap(
                store.operationGroups.loadAll().first {
                    $0.groupKind == ImageOwnershipLedger.groupKind &&
                        $0.plannedActionType == "prune"
                }
            )
            XCTAssertEqual(pruneGroup.status, .succeeded)
            XCTAssertEqual(
                pruneGroup.checkpoint,
                "provider-effect-verified"
            )
        }
    }

    func testActiveSharedLeaseExcludesContentFromPrunePlan()
        async throws
    {
        try await withHarness { harness in
            try harness.pull("registry.example/app:leased")
            let store = SQLiteStateStore(path: harness.statePath)
            let content = try XCTUnwrap(
                store.contentCache.listContent(
                    providerScope:
                        RuntimeProviderID.appleContainerCLI.rawValue
                ).first
            )
            let lease = try store.contentCache.acquireLease(
                providerScope:
                    RuntimeProviderID.appleContainerCLI.rawValue,
                digest: content.digest,
                mode: .shared,
                ownerID: "test-export",
                purpose: "test-export",
                acquiredAt: "2026-07-25T00:00:00Z",
                expiresAt: "2026-07-25T23:59:59Z"
            )
            defer {
                _ = try? store.contentCache.releaseLease(
                    id: lease.id,
                    expectedFencingToken: lease.fencingToken,
                    releasedAt: "2026-07-25T12:00:00Z"
                )
            }

            let preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            let plan = try XCTUnwrap(preview["plan"] as? [String: Any])
            XCTAssertTrue(
                (plan["candidates"] as? [[String: Any]])?.isEmpty ==
                    true
            )
            let contentEvidence = try XCTUnwrap(
                plan["content"] as? [[String: Any]]
            )
            XCTAssertEqual(
                contentEvidence.first?["reason"] as? String,
                "leased"
            )
            let stillPresent = await harness.provider.contains(
                "registry.example/app:leased"
            )
            XCTAssertTrue(stillPresent)
        }
    }

    func testUnmanagedAliasAndOperatorPinEachBlockPrune()
        async throws
    {
        try await withHarness { harness in
            let managed = "registry.example/app:managed"
            try harness.pull(managed)
            await harness.provider.addAlias(
                "registry.example/app:foreign",
                for: managed
            )

            var preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            var plan = try XCTUnwrap(
                preview["plan"] as? [String: Any]
            )
            var evidence = try XCTUnwrap(
                plan["content"] as? [[String: Any]]
            )
            XCTAssertEqual(
                evidence.first?["reason"] as? String,
                "unmanaged-reference"
            )

            await harness.provider.removeAlias(
                "registry.example/app:foreign"
            )
            _ = try harness.runJSON([
                "image", "cache", "pin", managed,
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            plan = try XCTUnwrap(
                preview["plan"] as? [String: Any]
            )
            evidence = try XCTUnwrap(
                plan["content"] as? [[String: Any]]
            )
            XCTAssertEqual(
                evidence.first?["reason"] as? String,
                "pinned"
            )

            _ = try harness.runJSON([
                "image", "cache", "unpin", managed,
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            plan = try XCTUnwrap(
                preview["plan"] as? [String: Any]
            )
            XCTAssertEqual(
                (plan["candidates"] as? [[String: Any]])?.count,
                1
            )
        }
    }

    func testCurrentDesiredDigestLockCreatesPolicyPin()
        async throws
    {
        try await withHarness { harness in
            let reference = "registry.example/app:desired"
            try harness.pull(reference)
            let store = SQLiteStateStore(path: harness.statePath)
            try store.desiredStates.saveManifestSnapshot(
                projectID: "project-cache-pin",
                manifestPath: "hostwright.yaml",
                manifestHash: "cache-pin-manifest",
                desiredGeneration: 1,
                manifest: HostwrightManifest(
                    project: "cache-pin",
                    services: [
                        HostwrightService(
                            name: "api",
                            image: reference
                        )
                    ]
                ),
                timestamp: "2026-07-25T00:00:00Z",
                mutationProvider:
                    RuntimeProviderID.appleContainerCLI.rawValue
            )
            let desiredService = try XCTUnwrap(
                store.desiredStates.loadDesiredServices(
                    projectID: "project-cache-pin"
                ).first
            )
            let plan = String(repeating: "9", count: 64)
            let lock = try RuntimeImageDigestLock(
                requestedReference: reference,
                resolvedReference:
                    "registry.example/app@\(ImageCacheTestProvider.descriptorDigest)",
                descriptorDigest:
                    ImageCacheTestProvider.descriptorDigest,
                variantDigest:
                    ImageCacheTestProvider.variantDigest,
                operatingSystem: "linux",
                architecture: "arm64",
                providerID: .appleContainerCLI,
                capabilitySHA256:
                    ImageCacheTestProvider.capabilitySHA256
            )
            try store.imageDigestLocks.save(
                ImageDigestLockRecord(
                    id: HostwrightResourceUUID.legacy(
                        kind: "image-digest-lock-desired",
                        identifier:
                            "\(plan):\(desiredService.resourceUUID)"
                    ),
                    projectID: "project-cache-pin",
                    resourceUUID: desiredService.resourceUUID,
                    serviceName: "api",
                    replicaIndex: 0,
                    stateKind: .desired,
                    lock: lock,
                    providerGeneration: 1,
                    planSHA256: plan,
                    operationGroupID:
                        HostwrightResourceUUID.legacy(
                            kind: "lifecycle-group",
                            identifier: plan
                        ),
                    observationSHA256: nil,
                    createdAt: "2026-07-25T00:00:00Z",
                    updatedAt: "2026-07-25T00:00:00Z"
                )
            )

            let preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            let prunePlan = try XCTUnwrap(
                preview["plan"] as? [String: Any]
            )
            let evidence = try XCTUnwrap(
                prunePlan["content"] as? [[String: Any]]
            )
            XCTAssertEqual(
                evidence.first?["reason"] as? String,
                "pinned"
            )
        }
    }

    func testStaleConfirmationFailsBeforeDeleteEffect()
        async throws
    {
        try await withHarness { harness in
            let reference = "registry.example/app:stale"
            try harness.pull(reference)
            let result = HostwrightCLI.run(
                arguments: [
                    "image", "prune",
                    "--confirm-plan",
                    String(repeating: "f", count: 64),
                    "--runtime-provider", "apple-cli",
                    "--state-db", harness.statePath,
                    "--json"
                ],
                environment: harness.environment
            )
            XCTAssertNotEqual(result.exitCode, 0)
            let stillPresent = await harness.provider.contains(reference)
            XCTAssertTrue(stillPresent)
        }
    }

    func testStaleOwnedReferenceAppearsInPlanAndConfirmedPruneCleansStateOnly()
        async throws
    {
        try await withHarness { harness in
            let reference = "registry.example/app:stale-owned"
            try harness.pull(reference)
            await harness.provider.removeAlias(reference)

            let preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            let plan = try XCTUnwrap(preview["plan"] as? [String: Any])
            let planSHA256 = try XCTUnwrap(
                plan["planSHA256"] as? String
            )
            XCTAssertTrue(
                (plan["candidates"] as? [[String: Any]])?.isEmpty ==
                    true
            )
            XCTAssertEqual(
                plan["staleOwnedReferences"] as? [String],
                [reference]
            )

            let execution = try harness.runJSON([
                "image", "prune",
                "--confirm-plan", planSHA256,
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            XCTAssertEqual(
                execution["disposition"] as? String,
                "unchanged"
            )
            XCTAssertEqual(
                execution["deletedReferences"] as? [String],
                [reference]
            )

            let store = SQLiteStateStore(path: harness.statePath)
            XCTAssertTrue(try store.imageOwnership.load().records.isEmpty)
            let cache = try store.contentCache.snapshot(
                providerScope:
                    RuntimeProviderID.appleContainerCLI.rawValue,
                currentTimestamp: "2026-07-25T12:00:00Z"
            )
            XCTAssertTrue(cache.contents.isEmpty)
            XCTAssertTrue(cache.references.isEmpty)
            XCTAssertTrue(cache.activeLeases.isEmpty)
            let pruneGroup = try XCTUnwrap(
                store.operationGroups.loadAll().first {
                    $0.groupKind == ImageOwnershipLedger.groupKind &&
                        $0.plannedActionType == "prune"
                }
            )
            XCTAssertEqual(pruneGroup.status, .succeeded)
        }
    }

    func testPinnedStaleOwnershipIsVisibleButNotPrunable()
        async throws
    {
        try await withHarness { harness in
            let reference = "registry.example/app:pinned-stale"
            try harness.pull(reference)
            _ = try harness.runJSON([
                "image", "cache", "pin", reference,
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            await harness.provider.removeAlias(reference)

            let status = try harness.runJSON([
                "image", "cache", "status",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            XCTAssertEqual(
                status["staleOwnedReferences"] as? [String],
                [reference]
            )
            XCTAssertEqual(
                status["prunableStaleOwnedReferences"] as? [String],
                []
            )
            let preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            let plan = try XCTUnwrap(
                preview["plan"] as? [String: Any]
            )
            XCTAssertEqual(
                plan["staleOwnedReferences"] as? [String],
                []
            )
            let store = SQLiteStateStore(path: harness.statePath)
            XCTAssertEqual(
                try store.imageOwnership.load().records
                    .map(\.reference),
                [reference]
            )
        }
    }

    func testConflictingRuntimeDigestFailsBeforePruneOrStateChange()
        async throws
    {
        try await withHarness { harness in
            let reference = "registry.example/app:conflict"
            try harness.pull(reference)
            await harness.provider.moveToConflictingDigest(reference)

            let result = HostwrightCLI.run(
                arguments: [
                    "image", "prune", "--dry-run",
                    "--runtime-provider", "apple-cli",
                    "--state-db", harness.statePath,
                    "--json"
                ],
                environment: harness.environment
            )
            XCTAssertNotEqual(result.exitCode, 0)
            let pruneMutations =
                await harness.provider.pruneMutationCount()
            XCTAssertEqual(pruneMutations, 0)
            let store = SQLiteStateStore(path: harness.statePath)
            XCTAssertEqual(
                try store.imageOwnership.load().records
                    .map(\.reference),
                [reference]
            )
        }
    }

    func testStaleReferenceReappearanceInvalidatesPlanBeforeDelete()
        async throws
    {
        try await withHarness { harness in
            let reference = "registry.example/app:reappears"
            try harness.pull(reference)
            await harness.provider.removeAlias(reference)
            let preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            let plan = try XCTUnwrap(
                preview["plan"] as? [String: Any]
            )
            let planSHA256 = try XCTUnwrap(
                plan["planSHA256"] as? String
            )
            await harness.provider.reappearAfterNextInventory(
                reference
            )

            let result = HostwrightCLI.run(
                arguments: [
                    "image", "prune",
                    "--confirm-plan", planSHA256,
                    "--runtime-provider", "apple-cli",
                    "--state-db", harness.statePath,
                    "--json"
                ],
                environment: harness.environment
            )
            XCTAssertNotEqual(result.exitCode, 0)
            let referencePresent =
                await harness.provider.contains(reference)
            let pruneMutations =
                await harness.provider.pruneMutationCount()
            XCTAssertTrue(referencePresent)
            XCTAssertEqual(pruneMutations, 0)
            let store = SQLiteStateStore(path: harness.statePath)
            XCTAssertEqual(
                try store.imageOwnership.load().records
                    .map(\.reference),
                [reference]
            )
        }
    }

    func testCancelledPruneLeavesExactResumableIntentAndReleasesLease()
        async throws
    {
        try await withHarness { harness in
            let reference = "registry.example/app:cancelled"
            try harness.pull(reference)
            let preview = try harness.runJSON([
                "image", "prune", "--dry-run",
                "--runtime-provider", "apple-cli",
                "--state-db", harness.statePath,
                "--json"
            ])
            let plan = try XCTUnwrap(preview["plan"] as? [String: Any])
            let planSHA256 = try XCTUnwrap(
                plan["planSHA256"] as? String
            )
            await harness.provider.cancelNextPrune()

            let result = HostwrightCLI.run(
                arguments: [
                    "image", "prune",
                    "--confirm-plan", planSHA256,
                    "--runtime-provider", "apple-cli",
                    "--state-db", harness.statePath,
                    "--json"
                ],
                environment: harness.environment
            )
            XCTAssertNotEqual(result.exitCode, 0)
            let stillPresent = await harness.provider.contains(reference)
            XCTAssertTrue(stillPresent)

            let store = SQLiteStateStore(path: harness.statePath)
            let snapshot = try store.contentCache.snapshot(
                providerScope:
                    RuntimeProviderID.appleContainerCLI.rawValue,
                currentTimestamp: "2026-07-25T12:00:00Z"
            )
            XCTAssertTrue(snapshot.activeLeases.isEmpty)
            let pruneGroup = try XCTUnwrap(
                store.operationGroups.loadAll().first {
                    $0.plannedActionType == "prune"
                }
            )
            XCTAssertEqual(pruneGroup.status, .interrupted)
            XCTAssertEqual(
                pruneGroup.checkpoint,
                "partial-effect-safe-hold"
            )
        }
    }

    private func withHarness(
        _ body: (ImageCacheHarness) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-image-cache-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ImageCacheTestProvider()
        let harness = ImageCacheHarness(
            statePath:
                directory.appendingPathComponent("state.sqlite").path,
            provider: provider
        )
        try await body(harness)
    }
}

private struct ImageCacheHarness {
    let statePath: String
    let provider: ImageCacheTestProvider

    fileprivate var environment: CLIEnvironment {
        CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in "" },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            runtimeAdapter: { provider },
            runtimeAdapterForProvider: { providerID in
                guard providerID == .appleContainerCLI else {
                    throw RuntimeProviderSelectionError
                        .providerUnavailable(providerID)
                }
                return provider
            },
            swiftVersion: { nil },
            platformSnapshot: {
                PlatformSnapshot(
                    macOSMajorVersion: 26,
                    architecture: "arm64"
                )
            },
            operatingSystemDescription: { "test" }
        )
    }

    func pull(_ reference: String) throws {
        let result = HostwrightCLI.run(
            arguments: [
                "image", "pull", reference,
                "--runtime-provider", "apple-cli",
                "--state-db", statePath,
                "--json"
            ],
            environment: environment
        )
        XCTAssertEqual(result.exitCode, 0, result.standardError)
    }

    func runJSON(_ arguments: [String]) throws -> [String: Any] {
        let result = HostwrightCLI.run(
            arguments: arguments,
            environment: environment
        )
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(result.standardOutput.utf8)
            ) as? [String: Any]
        )
    }
}

private actor ImageCacheTestProvider: RuntimeImageLifecycleProviding {
    fileprivate static let capabilitySHA256 =
        String(repeating: "a", count: 64)
    fileprivate static let descriptorDigest =
        "sha256:" + String(repeating: "b", count: 64)
    fileprivate static let variantDigest =
        "sha256:" + String(repeating: "c", count: 64)
    private var references: Set<String> = []
    private var conflictingReferences: Set<String> = []
    private var pendingReappearance: String?
    private var shouldCancelNextPrune = false
    private var pruneMutations = 0

    func contains(_ reference: String) -> Bool {
        references.contains(reference)
    }

    func addAlias(_ alias: String, for reference: String) {
        guard references.contains(reference) else { return }
        references.insert(alias)
    }

    func removeAlias(_ alias: String) {
        references.remove(alias)
        conflictingReferences.remove(alias)
    }

    func moveToConflictingDigest(_ reference: String) {
        guard references.contains(reference) else { return }
        conflictingReferences.insert(reference)
    }

    func reappearAfterNextInventory(_ reference: String) {
        pendingReappearance = reference
    }

    func pruneMutationCount() -> Int {
        pruneMutations
    }

    func cancelNextPrune() {
        shouldCancelNextPrune = true
    }

    func imageOperationCapabilities()
        async throws -> RuntimeImageOperationCapabilityContract
    {
        try RuntimeImageOperationCapabilityContract(
            providerID: .appleContainerCLI,
            capabilitySHA256: Self.capabilitySHA256,
            operations: RuntimeImageLifecycleOperation.allCases.map {
                RuntimeImageOperationCapability(
                    operation: $0,
                    state: .available,
                    reason: .implemented
                )
            }
        )
    }

    func performImageOperation(
        _ request: RuntimeImageLifecycleRequest,
        confirmation: RuntimeMutationConfirmation?,
        progress:
            @escaping @Sendable (RuntimeImageProgressEvent) async -> Void
    ) async throws -> RuntimeImageOperationResult {
        let plan = try request.planSHA256()
        switch request.operation {
        case .inspect:
            guard confirmation == nil else {
                throw RuntimeAdapterError
                    .mutationUnavailableByPolicy("test")
            }
            let requested = Set(request.sourceReferences)
            let images = references.isDisjoint(with: requested)
                ? []
                : [try record()]
            return try result(request, plan: plan, images: images)
        case .pull:
            try requireConfirmation(confirmation, plan: plan)
            references.formUnion(request.sourceReferences)
            return try result(
                request,
                plan: plan,
                images: [try record()]
            )
        case .delete, .prune:
            try requireConfirmation(confirmation, plan: plan)
            if request.operation == .prune {
                pruneMutations += 1
            }
            if request.operation == .prune,
               shouldCancelNextPrune {
                shouldCancelNextPrune = false
                throw RuntimeAdapterError.commandCancelled(
                    command: "image prune",
                    partialOutput: "",
                    partialError: ""
                )
            }
            for reference in request.sourceReferences {
                guard request.expectedSourceDigests[reference] ==
                        Self.descriptorDigest,
                      references.contains(reference) else {
                    throw RuntimeAdapterError
                        .mutationUnavailableByPolicy("test")
                }
            }
            references.subtract(request.sourceReferences)
            return try result(
                request,
                plan: plan,
                deletedDigests: references.isEmpty
                    ? [Self.descriptorDigest]
                    : []
            )
        case .push, .tag, .load, .save, .build:
            throw RuntimeAdapterError
                .mutationUnavailableByPolicy("test")
        }
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "ImageCacheTestProvider",
            adapterVersion: "test",
            runtimeName: "test",
            runtimeVersion: "1.1.0-test",
            supportsMutation: true,
            capabilities: [
                .readOnlyObservation,
                .lifecycleMutation
            ]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation]
    }

    func inventory() async throws -> RuntimeInventory {
        let snapshot = references
        let conflictingSnapshot = conflictingReferences
        if let pendingReappearance {
            references.insert(pendingReappearance)
            self.pendingReappearance = nil
        }
        let normalReferences =
            snapshot.subtracting(conflictingSnapshot)
        var images: [RuntimeInventoryImage] = []
        if !normalReferences.isEmpty {
            images.append(
                inventoryImage(
                    references: normalReferences,
                    descriptorDigest: Self.descriptorDigest,
                    variantDigest: Self.variantDigest
                )
            )
        }
        if !conflictingSnapshot.isEmpty {
            images.append(
                inventoryImage(
                    references: conflictingSnapshot,
                    descriptorDigest:
                        "sha256:" + String(repeating: "d", count: 64),
                    variantDigest:
                        "sha256:" + String(repeating: "e", count: 64)
                )
            )
        }
        return try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "linux",
                architecture: "arm64",
                runtimeVersion: "1.1.0-test",
                services: []
            ),
            containers: [],
            images: images,
            networks: [],
            volumes: []
        )
    }

    private func inventoryImage(
        references: Set<String>,
        descriptorDigest: String,
        variantDigest: String
    ) -> RuntimeInventoryImage {
        RuntimeInventoryImage(
            runtimeID: descriptorDigest,
            descriptorDigest: descriptorDigest,
            references: references.sorted(),
            variants: [
                RuntimeInventoryImageVariant(
                    digest: variantDigest,
                    architecture: "arm64",
                    operatingSystem: "linux"
                )
            ],
            labels: []
        )
    }

    func observe(
        desiredState: DesiredRuntimeState
    ) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: []
        )
    }

    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        RuntimePlan(actions: [])
    }

    func logs(
        for service: ObservedRuntimeService,
        tail: Int
    ) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError
            .capabilityUnavailable(.logStreaming)
    }

    func runtimeVersion() async throws -> String {
        "1.1.0-test"
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        throw RuntimeAdapterError
            .mutationUnavailableByPolicy("test")
    }

    private func requireConfirmation(
        _ confirmation: RuntimeMutationConfirmation?,
        plan: String
    ) throws {
        guard confirmation?.confirmed == true,
              confirmation?.planHash == plan else {
            throw RuntimeAdapterError
                .mutationUnavailableByPolicy("test")
        }
    }

    private func record() throws -> RuntimeImageRecord {
        try RuntimeImageRecord(
            digest: Self.descriptorDigest,
            references: references.sorted(),
            mediaType: "application/vnd.oci.image.index.v1+json",
            sizeBytes: 100,
            variants: [
                try RuntimeImageVariantRecord(
                    digest: Self.variantDigest,
                    operatingSystem: "linux",
                    architecture: "arm64",
                    sizeBytes: 100
                )
            ]
        )
    }

    private func result(
        _ request: RuntimeImageLifecycleRequest,
        plan: String,
        images: [RuntimeImageRecord] = [],
        deletedDigests: [String] = []
    ) throws -> RuntimeImageOperationResult {
        try RuntimeImageOperationResult(
            operation: request.operation,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            planSHA256: plan,
            providerID: .appleContainerCLI,
            providerVersion: "1.1.0-test",
            disposition: .succeeded,
            images: images,
            deletedDigests: deletedDigests
        )
    }
}
