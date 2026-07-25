import CryptoKit
import Foundation
import HostwrightCore
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class ImageLifecycleCoordinatorTests: XCTestCase {
    func testCLIEndToEndPullUsesDurableCoordinatorAndStructuredResult() throws {
        try withCoordinator { _, provider, store, environment in
            let reference = "registry.example.test/team/app:cli"

            let result = HostwrightCLI.run(
                arguments: [
                    "image", "pull", reference,
                    "--runtime-provider", "apple-cli",
                    "--state-db", store.configuration.databasePath,
                    "--progress", "none",
                    "--json"
                ],
                environment: environment
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardError.isEmpty)
            XCTAssertTrue(result.standardOutput.contains(#""kind":"imageOperation""#))
            XCTAssertTrue(result.standardOutput.contains(#""operation":"pull""#))
            XCTAssertFalse(result.standardOutput.contains(#""progress":[{"#))
            XCTAssertEqual(awaitValue { await provider.operations() }, [.pull])
            XCTAssertTrue(
                try store.imageOwnership.load().ownsReference(
                    reference,
                    providerID: RuntimeProviderID.appleContainerCLI.rawValue
                )
            )
        }
    }

    func testPullPersistsExactDigestOwnershipOnlyAfterVerifiedResult() throws {
        try withCoordinator { coordinator, provider, store, _ in
            let reference = "registry.example.test/team/app:v1"

            let execution = try coordinator.execute(
                input: ImageLifecycleInput(
                    operation: .pull,
                    sourceReferences: [reference]
                ),
                selection: .appleCLI
            )

            XCTAssertEqual(execution.createdReferences, [reference])
            let digest = try XCTUnwrap(execution.result.images.first?.digest)
            XCTAssertTrue(
                try store.imageOwnership.load().ownsExact(
                    reference: reference,
                    digest: digest,
                    providerID: RuntimeProviderID.appleContainerCLI.rawValue
                )
            )
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups[0].groupKind, ImageOwnershipLedger.groupKind)
            XCTAssertEqual(groups[0].status, .succeeded)
            XCTAssertEqual(groups[0].planHash, execution.result.planSHA256)
            XCTAssertEqual(
                try ImageOwnershipMetadataV1.decodeStrict(
                    groups[0].metadataJSONRedacted
                ).changes.first?.digest,
                digest
            )
            XCTAssertEqual(awaitValue { await provider.operations() }, [.pull])
        }
    }

    func testCreationCollisionIsRejectedBeforeProviderMutationOrIntent() throws {
        try withCoordinator { coordinator, provider, store, _ in
            let reference = "registry.example.test/team/app:existing"
            awaitValue {
                await provider.seed(reference: reference)
            }

            XCTAssertThrowsError(
                try coordinator.execute(
                    input: ImageLifecycleInput(
                        operation: .pull,
                        sourceReferences: [reference]
                    ),
                    selection: .appleCLI
                )
            ) { error in
                XCTAssertEqual(
                    (error as? HostwrightDiagnostic)?.code,
                    .imageConflict
                )
            }

            XCTAssertEqual(awaitValue { await provider.operations() }, [])
            XCTAssertEqual(try store.operationGroups.loadAll(), [])
        }
    }

    func testPartialPullFailureDeletesOnlyItsExactCreatedReference() throws {
        try withCoordinator(
            provider: ImageCoordinatorProvider(pullFailure: .command)
        ) { coordinator, provider, store, _ in
            let reference = "registry.example.test/team/app:partial"

            XCTAssertThrowsError(
                try coordinator.execute(
                    input: ImageLifecycleInput(
                        operation: .pull,
                        sourceReferences: [reference]
                    ),
                    selection: .appleCLI
                )
            )

            XCTAssertEqual(
                awaitValue { await provider.operations() },
                [.pull, .delete]
            )
            XCTAssertFalse(awaitValue { await provider.contains(reference) })
            let group = try XCTUnwrap(store.operationGroups.loadAll().first)
            XCTAssertEqual(group.status, .failed)
            XCTAssertEqual(group.checkpoint, "rolled-back")
            XCTAssertTrue(try store.imageOwnership.load().records.isEmpty)
        }
    }

    func testCancellationAfterPartialEffectCompensatesBeforeReturning() throws {
        try withCoordinator(
            provider: ImageCoordinatorProvider(pullFailure: .cancellation)
        ) { coordinator, provider, store, _ in
            let reference = "registry.example.test/team/app:cancelled"

            XCTAssertThrowsError(
                try coordinator.execute(
                    input: ImageLifecycleInput(
                        operation: .pull,
                        sourceReferences: [reference]
                    ),
                    selection: .appleCLI
                )
            ) { error in
                XCTAssertEqual(
                    (error as? HostwrightDiagnostic)?.code,
                    .imageCancelled
                )
            }

            XCTAssertFalse(awaitValue { await provider.contains(reference) })
            XCTAssertEqual(
                awaitValue { await provider.operations() },
                [.pull, .delete]
            )
            XCTAssertEqual(
                try store.operationGroups.loadAll().first?.checkpoint,
                "rolled-back"
            )
        }
    }

    func testPartialEffectEvidenceSurvivesImmediateInventoryFailure() throws {
        try withCoordinator(
            provider: ImageCoordinatorProvider(
                pullFailure: .reportedEffectThenInventoryFailure
            )
        ) { coordinator, provider, store, _ in
            let reference =
                "registry.example.test/team/app:durable-partial-effect"

            XCTAssertThrowsError(
                try coordinator.execute(
                    input: ImageLifecycleInput(
                        operation: .pull,
                        sourceReferences: [reference]
                    ),
                    selection: .appleCLI
                )
            )

            let digest = try XCTUnwrap(
                awaitValue { await provider.digest(for: reference) }
            )
            let group = try XCTUnwrap(store.operationGroups.loadAll().first)
            XCTAssertEqual(group.status, .interrupted)
            XCTAssertEqual(group.checkpoint, "partial-effect-safe-hold")
            let evidence = try ImageLifecyclePartialEffectEvidenceV1.decodeStrict(
                group.verificationJSONRedacted
            )
            XCTAssertEqual(
                evidence.createdReferences,
                [
                    ImageIntentReference(
                        reference: reference,
                        digest: digest
                    )
                ]
            )
        }
    }

    func testFailedSaveRemovesOnlyItsExactNewArchive() throws {
        try withCoordinator(
            provider: ImageCoordinatorProvider(failSaveAfterEffect: true)
        ) { coordinator, provider, store, _ in
            let reference = "registry.example.test/team/app:save"
            awaitValue {
                await provider.seed(reference: reference)
            }
            let archive = URL(
                fileURLWithPath: store.configuration.databasePath
            ).deletingLastPathComponent()
                .appendingPathComponent("image.oci").path

            XCTAssertThrowsError(
                try coordinator.execute(
                    input: ImageLifecycleInput(
                        operation: .save,
                        sourceReferences: [reference],
                        archivePath: archive
                    ),
                    selection: .appleCLI
                )
            )

            XCTAssertFalse(FileManager.default.fileExists(atPath: archive))
            XCTAssertEqual(
                try store.operationGroups.loadAll().first?.checkpoint,
                "rolled-back"
            )
            XCTAssertEqual(
                awaitValue { await provider.operations() },
                [.inspect, .save]
            )
        }
    }

    func testExactArchiveCleanupRefusesSymlinkWithoutRemovingEitherPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-image-cleanup-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.oci")
        let link = directory.appendingPathComponent("output.oci")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: target.path,
                contents: Data("owned target".utf8)
            )
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try removeExactOwnedImageArchiveIfPresent(link.path)
        ) { error in
            XCTAssertEqual(
                (error as? HostwrightDiagnostic)?.code,
                .imageDenied
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNotNil(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        )
    }

    func testDeleteRefusesOwnedContentReferencedByLiveContainer() throws {
        try withCoordinator { coordinator, provider, store, _ in
            let reference = "registry.example.test/team/app:live"
            _ = try coordinator.execute(
                input: ImageLifecycleInput(
                    operation: .pull,
                    sourceReferences: [reference]
                ),
                selection: .appleCLI
            )
            awaitValue {
                await provider.setLiveReference(reference)
            }
            let priorOperations = awaitValue { await provider.operations() }

            XCTAssertThrowsError(
                try coordinator.execute(
                    input: ImageLifecycleInput(
                        operation: .delete,
                        sourceReferences: [reference]
                    ),
                    selection: .appleCLI
                )
            ) { error in
                XCTAssertEqual(
                    (error as? HostwrightDiagnostic)?.code,
                    .imageConflict
                )
            }

            XCTAssertEqual(
                awaitValue { await provider.operations() },
                priorOperations
            )
            XCTAssertTrue(
                try store.imageOwnership.load().ownsReference(
                    reference,
                    providerID: RuntimeProviderID.appleContainerCLI.rawValue
                )
            )
        }
    }

    func testPruneDeletesOnlyOwnedUnreferencedContent() throws {
        try withCoordinator { coordinator, provider, store, _ in
            let retained = "registry.example.test/team/app:retained"
            let pruned = "registry.example.test/team/app:pruned"
            for reference in [retained, pruned] {
                _ = try coordinator.execute(
                    input: ImageLifecycleInput(
                        operation: .pull,
                        sourceReferences: [reference]
                    ),
                    selection: .appleCLI
                )
            }
            awaitValue {
                await provider.setLiveReference(retained)
            }

            let execution = try coordinator.execute(
                input: ImageLifecycleInput(operation: .prune),
                selection: .appleCLI
            )

            XCTAssertEqual(execution.deletedReferences, [pruned])
            XCTAssertTrue(awaitValue { await provider.contains(retained) })
            XCTAssertFalse(awaitValue { await provider.contains(pruned) })
            let ownership = try store.imageOwnership.load()
            XCTAssertTrue(
                ownership.ownsReference(
                    retained,
                    providerID: RuntimeProviderID.appleContainerCLI.rawValue
                )
            )
            XCTAssertFalse(
                ownership.ownsReference(
                    pruned,
                    providerID: RuntimeProviderID.appleContainerCLI.rawValue
                )
            )
            let pruneRequest = try XCTUnwrap(
                awaitValue { await provider.requests() }.last
            )
            XCTAssertEqual(pruneRequest.operation, .prune)
            XCTAssertEqual(pruneRequest.sourceReferences, [pruned])
        }
    }

    func testInterruptedCreationRecoveryCanCommitObservedDigest() throws {
        try withCoordinator { _, provider, store, environment in
            let reference = "registry.example.test/team/app:recovered"
            awaitValue {
                await provider.seed(reference: reference)
            }
            let digest = try XCTUnwrap(
                awaitValue { await provider.digest(for: reference) }
            )
            let group = try interruptedCreationGroup(
                reference: reference,
                provider: provider,
                store: store,
                createdDigest: digest
            )

            let result = try ImagePersistedRecoveryDriver(
                environment: environment
            ).execute(
                LifecyclePersistedRecoveryRequest(
                    action: .resume,
                    groupID: group.id,
                    confirmationPlanSHA256: group.planHash,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: store.configuration.databasePath
                    ),
                    timeoutSeconds: 30
                ),
                sourceGroup: group
            )

            XCTAssertEqual(result.status, .succeeded)
            let recovered = try XCTUnwrap(
                store.imageOwnership.load().record(
                    forReference: reference,
                    providerID:
                        RuntimeProviderID.appleContainerCLI.rawValue
                )
            )
            XCTAssertEqual(
                recovered.digest,
                awaitValue { await provider.digest(for: reference) }
            )
            XCTAssertEqual(
                try store.operationGroups.load(id: group.id)?.status,
                .succeeded
            )
            let cache = try store.contentCache.snapshot(
                providerScope:
                    RuntimeProviderID.appleContainerCLI.rawValue,
                currentTimestamp: imageLifecycleTimestamp()
            )
            XCTAssertEqual(cache.contents.map(\.digest), [digest])
            XCTAssertEqual(
                cache.references.map(\.reference),
                [reference]
            )
            XCTAssertTrue(cache.activeLeases.isEmpty)
            XCTAssertEqual(cache.contents.first?.sizeBytes, 1)
        }
    }

    func testRecoveryCLIExecutesPersistedImageRecoveryDriver() throws {
        try withCoordinator { _, provider, store, environment in
            let reference = "registry.example.test/team/app:recovery-cli"
            awaitValue {
                await provider.seed(reference: reference)
            }
            let digest = try XCTUnwrap(
                awaitValue { await provider.digest(for: reference) }
            )
            let group = try interruptedCreationGroup(
                reference: reference,
                provider: provider,
                store: store,
                createdDigest: digest
            )

            let result = HostwrightCLI.run(
                arguments: [
                    "recovery", "resume",
                    "--group", group.id,
                    "--confirm-plan", group.planHash,
                    "--state-db", store.configuration.databasePath,
                    "--output", "json"
                ],
                environment: environment
            )

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertTrue(result.standardError.isEmpty)
            XCTAssertTrue(result.standardOutput.contains(#""status":"succeeded""#))
            XCTAssertTrue(
                try store.imageOwnership.load().ownsReference(
                    reference,
                    providerID: RuntimeProviderID.appleContainerCLI.rawValue
                )
            )
        }
    }

    func testInterruptedCreationRollbackDeletesOnlyPersistedCreatedReference() throws {
        try withCoordinator { _, provider, store, environment in
            let reference = "registry.example.test/team/app:rollback"
            awaitValue {
                await provider.seed(reference: reference)
            }
            let digest = try XCTUnwrap(
                awaitValue { await provider.digest(for: reference) }
            )
            let group = try interruptedCreationGroup(
                reference: reference,
                provider: provider,
                store: store,
                createdDigest: digest
            )

            let result = try ImagePersistedRecoveryDriver(
                environment: environment
            ).execute(
                LifecyclePersistedRecoveryRequest(
                    action: .rollback,
                    groupID: group.id,
                    confirmationPlanSHA256: group.planHash,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: store.configuration.databasePath
                    ),
                    timeoutSeconds: 30
                ),
                sourceGroup: group
            )

            XCTAssertEqual(result.status, .compensated)
            XCTAssertFalse(awaitValue { await provider.contains(reference) })
            XCTAssertEqual(
                awaitValue { await provider.operations() },
                [.delete]
            )
            XCTAssertEqual(
                try store.operationGroups.load(id: group.id)?.status,
                .failed
            )
        }
    }

    func testInterruptedCreationWithoutDurableDigestProofCannotAdoptForeignContent() throws {
        try withCoordinator { _, provider, store, environment in
            let reference = "registry.example.test/team/app:foreign-after-crash"
            let group = try interruptedCreationGroup(
                reference: reference,
                provider: provider,
                store: store
            )
            awaitValue {
                await provider.seed(reference: reference)
            }

            XCTAssertThrowsError(
                try ImagePersistedRecoveryDriver(
                    environment: environment
                ).execute(
                    LifecyclePersistedRecoveryRequest(
                        action: .resume,
                        groupID: group.id,
                        confirmationPlanSHA256: group.planHash,
                        stateStoreConfiguration: StateStoreConfiguration(
                            explicitDatabasePath: store.configuration.databasePath
                        ),
                        timeoutSeconds: 30
                    ),
                    sourceGroup: group
                )
            ) { error in
                guard case LifecyclePersistedRecoveryError.safeHold = error else {
                    return XCTFail("Expected missing-digest safe hold.")
                }
            }

            XCTAssertTrue(awaitValue { await provider.contains(reference) })
            XCTAssertEqual(awaitValue { await provider.operations() }, [])
            XCTAssertFalse(
                try store.imageOwnership.load().ownsReference(
                    reference,
                    providerID: RuntimeProviderID.appleContainerCLI.rawValue
                )
            )
        }
    }

    func testInterruptedRecoveryRefusesChangedProviderCapabilityBeforeEffects() throws {
        try withCoordinator { _, provider, store, environment in
            let reference = "registry.example.test/team/app:capability-change"
            let group = try interruptedCreationGroup(
                reference: reference,
                provider: provider,
                store: store
            )
            awaitValue {
                await provider.seed(reference: reference)
                await provider.changeCapability()
            }

            XCTAssertThrowsError(
                try ImagePersistedRecoveryDriver(
                    environment: environment
                ).execute(
                    LifecyclePersistedRecoveryRequest(
                        action: .resume,
                        groupID: group.id,
                        confirmationPlanSHA256: group.planHash,
                        stateStoreConfiguration: StateStoreConfiguration(
                            explicitDatabasePath: store.configuration.databasePath
                        ),
                        timeoutSeconds: 30
                    ),
                    sourceGroup: group
                )
            ) { error in
                guard case LifecyclePersistedRecoveryError.safeHold = error else {
                    return XCTFail("Expected capability-change safe hold.")
                }
            }

            XCTAssertEqual(awaitValue { await provider.operations() }, [])
            XCTAssertEqual(
                try store.operationGroups.load(id: group.id)?.status,
                .interrupted
            )
        }
    }

    private func interruptedCreationGroup(
        reference: String,
        provider: ImageCoordinatorProvider,
        store: SQLiteStateStore,
        createdDigest: String? = nil
    ) throws -> OperationGroupRecord {
        try store.migrate()
        let capability = try hostwrightWaitForAsync {
            try await provider.imageOperationCapabilities()
        }
        let request = try RuntimeImageLifecycleRequest(
            operation: .pull,
            operationID: UUID().uuidString.lowercased(),
            idempotencyKey:
                "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            capabilitySHA256: capability.capabilitySHA256,
            sourceReferences: [reference]
        )
        let intent = ImageLifecycleIntentV1(
            providerID: .appleContainerCLI,
            request: request,
            createdReferences: [reference],
            priorReferences: [],
            removedOwnership: []
        )
        let timestamp = imageLifecycleTimestamp()
        let verification = try createdDigest.map {
            try ImageLifecyclePartialEffectEvidenceV1(
                createdReferences: [
                    ImageIntentReference(reference: reference, digest: $0)
                ]
            ).canonicalJSONString()
        } ?? "{}"
        let record = OperationGroupRecord(
            id: request.operationID,
            operationID: request.operationID,
            groupKind: ImageOwnershipLedger.groupKind,
            projectID: "image-provider-apple-container-cli",
            serviceName: nil,
            plannedActionType: request.operation.rawValue,
            status: .active,
            groupIdempotencyKey:
                "\(ImageOwnershipLedger.groupKind):\(request.idempotencyKey)",
            planHash: try request.planSHA256(),
            checkpoint: "prepared",
            lockOwner: nil,
            lockExpiresAt: nil,
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "recover exact image intent",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: try ImageOwnershipMetadataV1(
                changes: []
            ).canonicalJSONString(),
            intentJSONRedacted: try intent.canonicalJSONString(),
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: verification
        )
        let acquired = try XCTUnwrap(
            store.operationGroups.acquire(record).acquired
        )
        try store.operationGroups.finish(
            groupID: acquired.id,
            status: .interrupted,
            checkpoint: "partial-effect-safe-hold",
            manualRecoveryHintRedacted: "recover exact image intent",
            updatedAt: imageLifecycleTimestamp(),
            metadataJSONRedacted: try ImageOwnershipMetadataV1(
                changes: []
            ).canonicalJSONString()
        )
        let loaded = try XCTUnwrap(
            store.operationGroups.load(id: acquired.id)
        )
        if createdDigest != nil {
            XCTAssertNoThrow(
                try ImageLifecyclePartialEffectEvidenceV1.decodeStrict(
                    loaded.verificationJSONRedacted
                )
            )
        }
        return loaded
    }

    private func withCoordinator(
        provider: ImageCoordinatorProvider = ImageCoordinatorProvider(),
        body: (
            ImageLifecycleCoordinator,
            ImageCoordinatorProvider,
            SQLiteStateStore,
            CLIEnvironment
        ) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-image-coordinator-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = StateStoreConfiguration(
            explicitDatabasePath: directory
                .appendingPathComponent("state.sqlite").path
        )
        let store = SQLiteStateStore(configuration: configuration)
        let environment = CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in "" },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            runtimeAdapter: { provider },
            runtimeAdapterForProvider: { providerID in
                guard providerID == .appleContainerCLI else {
                    throw RuntimeProviderSelectionError.providerUnavailable(
                        providerID
                    )
                }
                return provider
            },
            swiftVersion: { nil },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "test" }
        )
        try body(
            ImageLifecycleCoordinator(
                environment: environment,
                stateStoreConfiguration: configuration
            ),
            provider,
            store,
            environment
        )
    }

    private func awaitValue<T: Sendable>(
        _ body: @escaping @Sendable () async -> T
    ) -> T {
        try! hostwrightWaitForAsync(body)
    }
}

private actor ImageCoordinatorProvider: RuntimeImageLifecycleProviding {
    enum PullFailure: Sendable {
        case command
        case cancellation
        case reportedEffectThenInventoryFailure
    }

    private static let capabilitySHA256 =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let changedCapabilitySHA256 =
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    private static let variantDigest =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private static let layerDigest =
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    private var digestsByReference: [String: String] = [:]
    private var liveReference: String?
    private var operationLog: [RuntimeImageLifecycleOperation] = []
    private var requestLog: [RuntimeImageLifecycleRequest] = []
    private let pullFailure: PullFailure?
    private let failSaveAfterEffect: Bool
    private var pullFailureConsumed = false
    private var inventoryFailurePending = false
    private var capabilitySHA256: String

    init(
        pullFailure: PullFailure? = nil,
        failSaveAfterEffect: Bool = false
    ) {
        self.pullFailure = pullFailure
        self.failSaveAfterEffect = failSaveAfterEffect
        self.capabilitySHA256 = ImageCoordinatorProvider.capabilitySHA256
    }

    func seed(reference: String) {
        digestsByReference[reference] = Self.digest(for: reference)
    }

    func setLiveReference(_ reference: String?) {
        liveReference = reference
    }

    func changeCapability() {
        capabilitySHA256 = Self.changedCapabilitySHA256
    }

    func contains(_ reference: String) -> Bool {
        digestsByReference[reference] != nil
    }

    func digest(for reference: String) -> String? {
        digestsByReference[reference]
    }

    func operations() -> [RuntimeImageLifecycleOperation] {
        operationLog
    }

    func requests() -> [RuntimeImageLifecycleRequest] {
        requestLog
    }

    func imageOperationCapabilities()
        async throws -> RuntimeImageOperationCapabilityContract
    {
        try RuntimeImageOperationCapabilityContract(
            providerID: .appleContainerCLI,
            capabilitySHA256: capabilitySHA256,
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
        progress: @escaping @Sendable (RuntimeImageProgressEvent) async -> Void
    ) async throws -> RuntimeImageOperationResult {
        requestLog.append(request)
        operationLog.append(request.operation)
        if request.operation != .inspect {
            let planSHA256 = try request.planSHA256()
            guard confirmation?.confirmed == true,
                  confirmation?.planHash == planSHA256 else {
                throw RuntimeAdapterError.commandRejected(
                    classification: .mutating,
                    message: "missing confirmation"
                )
            }
        }
        await progress(
            try RuntimeImageProgressEvent(
                operation: request.operation,
                operationID: request.operationID,
                idempotencyKey: request.idempotencyKey,
                sequence: 0,
                stage: .resolving,
                completedBytes: 0
            )
        )

        let before = digestsByReference
        switch request.operation {
        case .pull, .load:
            for reference in request.sourceReferences {
                digestsByReference[reference] = Self.digest(for: reference)
            }
        case .build:
            digestsByReference[request.targetReference!] = Self.digest(
                for: request.targetReference!
            )
        case .tag:
            guard let digest = digestsByReference[request.sourceReferences[0]]
            else {
                throw RuntimeAdapterError.outputParseFailed("missing source")
            }
            digestsByReference[request.targetReference!] = digest
        case .delete, .prune:
            for reference in request.sourceReferences {
                digestsByReference.removeValue(forKey: reference)
            }
        case .save:
            if failSaveAfterEffect,
               let archivePath = request.archivePath {
                guard FileManager.default.createFile(
                    atPath: archivePath,
                    contents: Data("partial".utf8)
                ) else {
                    throw RuntimeAdapterError.commandFailed(
                        exitStatus: 1,
                        message: "could not create partial archive",
                        standardError: ""
                    )
                }
            }
        case .push, .inspect:
            break
        }

        if request.operation == .pull,
           let pullFailure,
           !pullFailureConsumed {
            pullFailureConsumed = true
            switch pullFailure {
            case .command:
                throw RuntimeAdapterError.commandFailed(
                    exitStatus: 1,
                    message: "simulated failure",
                    standardError: ""
                )
            case .cancellation:
                throw CancellationError()
            case .reportedEffectThenInventoryFailure:
                inventoryFailurePending = true
                let reference = request.sourceReferences[0]
                throw try RuntimeImagePartialEffectError(
                    operation: .pull,
                    createdReferences: [
                        RuntimeImageReferenceDigest(
                            reference: reference,
                            digest: digestsByReference[reference]!
                        )
                    ]
                )
            }
        }
        if request.operation == .save, failSaveAfterEffect {
            throw RuntimeAdapterError.commandFailed(
                exitStatus: 1,
                message: "simulated save failure",
                standardError: ""
            )
        }
        let relevant: [String]
        switch request.operation {
        case .build, .tag:
            relevant = [request.targetReference!]
        case .delete, .prune:
            relevant = []
        default:
            relevant = request.sourceReferences
        }
        let records = try relevant.compactMap { reference -> RuntimeImageRecord? in
            guard let digest = digestsByReference[reference] else {
                return nil
            }
            return try Self.record(reference: reference, digest: digest)
        }
        let deleted = request.operation == .delete || request.operation == .prune
            ? request.sourceReferences.compactMap { before[$0] }
            : []
        return try RuntimeImageOperationResult(
            operation: request.operation,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            planSHA256: request.planSHA256(),
            providerID: .appleContainerCLI,
            providerVersion: "1.1.0-test",
            disposition: before == digestsByReference ? .unchanged : .succeeded,
            images: records,
            deletedDigests: deleted
        )
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "ImageCoordinatorProvider",
            adapterVersion: "test",
            runtimeName: "test",
            runtimeVersion: "1.1.0-test",
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation]
    }

    func inventory() async throws -> RuntimeInventory {
        if inventoryFailurePending {
            inventoryFailurePending = false
            throw RuntimeAdapterError.outputParseFailed(
                "simulated immediate inventory failure"
            )
        }
        let images = digestsByReference.keys.sorted().map { reference in
            RuntimeInventoryImage(
                runtimeID:
                    "runtime-\(digestsByReference[reference]!.dropFirst("sha256:".count).prefix(16))",
                descriptorDigest: digestsByReference[reference]!,
                references: [reference],
                variants: [
                    RuntimeInventoryImageVariant(
                        digest: Self.variantDigest,
                        architecture: "arm64",
                        operatingSystem: "linux"
                    )
                ],
                labels: []
            )
        }
        let containers: [RuntimeInventoryContainer]
        if let liveReference,
           let digest = digestsByReference[liveReference] {
            containers = [
                RuntimeInventoryContainer(
                    runtimeID: "container-live",
                    name: "live",
                    imageID: digest,
                    imageReference: liveReference,
                    lifecycle: .running,
                    health: RuntimeInventoryHealth(
                        availability: .notConfigured
                    ),
                    labels: [],
                    initConfiguration: RuntimeInventoryInitConfiguration(
                        executable: "/bin/sh",
                        arguments: [],
                        environment: []
                    ),
                    ports: [],
                    mounts: [],
                    networks: [],
                    services: []
                )
            ]
        } else {
            containers = []
        }
        return try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "linux",
                architecture: "arm64",
                runtimeVersion: "1.1.0-test",
                services: []
            ),
            containers: containers,
            images: images,
            networks: [],
            volumes: []
        )
    }

    func observe(
        desiredState: DesiredRuntimeState
    ) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(projectName: desiredState.projectName, services: [])
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
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func runtimeVersion() async throws -> String {
        "1.1.0-test"
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableByPolicy("test")
    }

    private static func record(
        reference: String,
        digest: String
    ) throws -> RuntimeImageRecord {
        try RuntimeImageRecord(
            digest: digest,
            references: [reference],
            mediaType: "application/vnd.oci.image.index.v1+json",
            sizeBytes: 1,
            variants: [
                try RuntimeImageVariantRecord(
                    digest: variantDigest,
                    operatingSystem: "linux",
                    architecture: "arm64",
                    sizeBytes: 1,
                    layerDigests: [layerDigest]
                )
            ]
        )
    }

    private static func digest(for reference: String) -> String {
        let value = SHA256.hash(data: Data(reference.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(value)"
    }

    private static func shortHash(_ value: String) -> String {
        let bytes = Array(value.utf8)
        return (0..<8).map { index in
            String(format: "%02x", bytes[index % bytes.count])
        }.joined()
    }
}
