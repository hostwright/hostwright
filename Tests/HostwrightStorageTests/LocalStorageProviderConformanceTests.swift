import CryptoKit
import Foundation
import HostwrightSecrets
import HostwrightStorage
import XCTest

final class LocalStorageProviderConformanceTests: XCTestCase {
    func testBuiltInAndInjectedTestProviderPassOneConformanceSuite() async throws {
        let first = try LocalStorageProviderTestHarness()
        defer { first.cleanup() }
        let builtIn = try LocalStorageProvider(
            rootURL: first.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            backupKeyResolver: ConformanceBackupKeyResolver()
        )
        try await runConformance(provider: builtIn)

        let second = try LocalStorageProviderTestHarness()
        defer { second.cleanup() }
        let testProvider = ForwardingStorageTestProvider(
            provider: try LocalStorageProvider(
                rootURL: second.providerRoot,
                totalCapacityBytes: 16 * 1_024 * 1_024,
                backupKeyResolver: ConformanceBackupKeyResolver()
            )
        )
        try await runConformance(provider: testProvider)
    }

    private func runConformance(
        provider: any StorageProviderSPI
    ) async throws {
        let descriptor = try await provider.descriptor()
        XCTAssertEqual(
            descriptor.providerID,
            LocalStorageProviderContract.providerID
        )
        for operation in [
            StorageProviderOperation.create,
            .observe,
            .attach,
            .detach,
            .snapshot,
            .backup,
            .restore,
            .expand,
            .delete,
            .health,
            .recovery
        ] {
            XCTAssertEqual(
                descriptor.capability(for: operation)?.state,
                .available
            )
        }
        let dispatcher = try await StorageProviderTransportDispatcher.make(
            provider: provider
        )
        let identity = LocalStorageTestIdentity()
        let restoreIdentity = LocalStorageTestIdentity(
            projectUUID: identity.projectUUID
        )

        let create = LocalStorageProviderTestRequest(
            operation: .create,
            context: identity.context(resourceGeneration: 1),
            idempotencyKey: "create-\(identity.volumeID)",
            payload: LocalStorageCreatePayload(
                name: "conformance-volume",
                capacityBytes: 1_024 * 1_024
            )
        )
        let created: LocalStorageMutationResult = try await invoke(
            create,
            dispatcher: dispatcher
        )
        XCTAssertEqual(created.disposition, .performed)
        XCTAssertEqual(created.volume?.volumeID, identity.volumeID)
        XCTAssertTrue(created.volume?.attachments.isEmpty == true)

        let repeated = LocalStorageProviderTestRequest(
            operation: .create,
            context: identity.context(resourceGeneration: 1),
            idempotencyKey: create.idempotencyKey,
            payload: create.payload
        )
        let repeatedResult: LocalStorageMutationResult = try await invoke(
            repeated,
            dispatcher: dispatcher
        )
        XCTAssertEqual(
            repeatedResult.volume?.volumeID,
            identity.volumeID
        )

        let observation: LocalStorageObservation = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .observe,
                context: nil,
                idempotencyKey: "observe-\(identity.volumeID)",
                payload: LocalStorageObservePayload(
                    volumeID: identity.volumeID
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(observation.volumes.count, 1)
        XCTAssertEqual(observation.reservedCapacityBytes, 1_024 * 1_024)

        let restoreTarget: LocalStorageMutationResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .create,
                context: restoreIdentity.context(resourceGeneration: 1),
                idempotencyKey: "create-\(restoreIdentity.volumeID)",
                payload: LocalStorageCreatePayload(
                    name: "conformance-restore-target",
                    capacityBytes: 1_024 * 1_024
                )
            ),
            dispatcher: dispatcher
        )
        let sourcePath = try XCTUnwrap(created.volume?.dataPath)
        let restorePath = try XCTUnwrap(
            restoreTarget.volume?.dataPath
        )
        try Data("conformance-data".utf8).write(
            to: URL(fileURLWithPath: sourcePath)
                .appendingPathComponent("value.txt")
        )
        try Data("before-restore".utf8).write(
            to: URL(fileURLWithPath: restorePath)
                .appendingPathComponent("value.txt")
        )

        let attachmentID = UUID().uuidString.lowercased()
        let detachBeforeAttach: LocalStorageMutationResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .detach,
                context: identity.context(
                    resourceGeneration: 1,
                    attachmentGeneration: 1
                ),
                idempotencyKey: "detach-before-\(attachmentID)",
                payload: LocalStorageDetachPayload(
                    attachmentID: attachmentID,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        identity.firstFence.uuidString.lowercased(),
                    expectedAttachmentGeneration: 1,
                    expectedAttachmentFencingToken:
                        identity.firstFence.uuidString.lowercased()
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(
            detachBeforeAttach.disposition,
            .alreadySatisfied
        )

        let attached: LocalStorageMutationResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .attach,
                context: identity.context(
                    resourceGeneration: 1,
                    attachmentGeneration: 1
                ),
                idempotencyKey: "attach-\(attachmentID)",
                payload: LocalStorageAttachPayload(
                    attachmentID: attachmentID,
                    consumerID: "conformance-consumer",
                    readOnly: false,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        identity.firstFence.uuidString.lowercased()
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(attached.volume?.attachments.count, 1)

        let detached: LocalStorageMutationResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .detach,
                context: identity.context(
                    resourceGeneration: 1,
                    attachmentGeneration: 1
                ),
                idempotencyKey: "detach-\(attachmentID)",
                payload: LocalStorageDetachPayload(
                    attachmentID: attachmentID,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        identity.firstFence.uuidString.lowercased(),
                    expectedAttachmentGeneration: 1,
                    expectedAttachmentFencingToken:
                        identity.firstFence.uuidString.lowercased()
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertTrue(detached.volume?.attachments.isEmpty == true)

        let snapshotID = UUID().uuidString.lowercased()
        let snapshot: LocalStorageSnapshotResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .snapshot,
                context: identity.context(resourceGeneration: 1),
                idempotencyKey: "snapshot-\(snapshotID)",
                payload: LocalStorageSnapshotPayload(
                    snapshotID: snapshotID,
                    name: "conformance-snapshot"
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(snapshot.sourceVolumeID, identity.volumeID)
        XCTAssertEqual(snapshot.contentTreeSHA256.utf8.count, 64)

        let snapshotRestore: LocalStorageRestoreResult =
            try await invoke(
                LocalStorageProviderTestRequest(
                    operation: .restore,
                    context: restoreIdentity.context(
                        resourceGeneration: 1
                    ),
                    idempotencyKey:
                        "snapshot-restore-\(snapshotID)",
                    payload: LocalStorageRestorePayload(
                        source: .snapshot,
                        sourceID: snapshotID,
                        referenceID:
                            UUID().uuidString.lowercased(),
                        targets: [
                            LocalStorageRestoreTargetPayload(
                                sourceVolumeID:
                                    identity.volumeID,
                                targetVolumeID:
                                    restoreIdentity.volumeID,
                                generation: 1,
                                fencingToken:
                                    restoreIdentity.firstFence
                                        .uuidString.lowercased()
                            ),
                        ]
                    )
                ),
                dispatcher: dispatcher
            )
        XCTAssertEqual(
            snapshotRestore.restoredTargetVolumeIDs,
            [restoreIdentity.volumeID]
        )
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: restorePath)
                    .appendingPathComponent("value.txt"),
                encoding: .utf8
            ),
            "conformance-data"
        )

        let backupID = UUID().uuidString.lowercased()
        let keyReference = "keychain://hostwright-tests/conformance"
        let backupVolumes = [
            LocalStorageBackupVolumePayload(
                volumeID: identity.volumeID,
                generation: 1,
                fencingToken:
                    identity.firstFence.uuidString.lowercased()
            ),
        ]
        let backup: LocalStorageBackupResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .backup,
                context: identity.context(resourceGeneration: 1),
                idempotencyKey: "backup-\(backupID)",
                payload: LocalStorageBackupPayload(
                    backupID: backupID,
                    name: "conformance-backup",
                    keyReference: keyReference,
                    volumes: backupVolumes
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(backup.verifiedVolumeIDs, [identity.volumeID])
        XCTAssertEqual(backup.manifestSHA256.utf8.count, 64)

        let verifiedBackup: LocalStorageBackupResult =
            try await invoke(
                LocalStorageProviderTestRequest(
                    operation: .backup,
                    context: identity.context(
                        resourceGeneration: 1
                    ),
                    idempotencyKey: "backup-verify-\(backupID)",
                    payload: LocalStorageBackupPayload(
                        action: .verify,
                        backupID: backupID,
                        keyReference: keyReference,
                        volumes: backupVolumes,
                        expectedManifestSHA256:
                            backup.manifestSHA256
                    )
                ),
                dispatcher: dispatcher
            )
        XCTAssertEqual(
            verifiedBackup.manifestSHA256,
            backup.manifestSHA256
        )

        let backupRestore: LocalStorageRestoreResult =
            try await invoke(
                LocalStorageProviderTestRequest(
                    operation: .restore,
                    context: restoreIdentity.context(
                        resourceGeneration: 1
                    ),
                    idempotencyKey:
                        "backup-restore-\(backupID)",
                    payload: LocalStorageRestorePayload(
                        source: .backup,
                        sourceID: backupID,
                        expectedManifestSHA256:
                            backup.manifestSHA256,
                        keyReference: keyReference,
                        targets: [
                            LocalStorageRestoreTargetPayload(
                                sourceVolumeID:
                                    identity.volumeID,
                                targetVolumeID:
                                    restoreIdentity.volumeID,
                                generation: 1,
                                fencingToken:
                                    restoreIdentity.firstFence
                                        .uuidString.lowercased()
                            ),
                        ]
                    )
                ),
                dispatcher: dispatcher
            )
        XCTAssertEqual(
            backupRestore.restoredTargetVolumeIDs,
            [restoreIdentity.volumeID]
        )

        let recovery: LocalStorageRecoveryResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .recovery,
                context: identity.context(resourceGeneration: 1),
                idempotencyKey: "recovery-\(identity.volumeID)",
                payload: LocalStorageRecoveryPayload(
                    idempotencyKey: create.idempotencyKey
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(recovery.disposition, .alreadySatisfied)
        XCTAssertEqual(recovery.recoveredOperation, .create)

        let removedRestoreTarget: LocalStorageMutationResult =
            try await invoke(
                LocalStorageProviderTestRequest(
                    operation: .delete,
                    context: restoreIdentity.context(
                        resourceGeneration: 1
                    ),
                    idempotencyKey:
                        "delete-\(restoreIdentity.volumeID)",
                    payload: LocalStorageDeletePayload()
                ),
                dispatcher: dispatcher
            )
        XCTAssertEqual(
            removedRestoreTarget.removedVolumeID,
            restoreIdentity.volumeID
        )

        let deletedBackup: LocalStorageBackupResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .backup,
                context: identity.context(resourceGeneration: 1),
                idempotencyKey: "backup-delete-\(backupID)",
                payload: LocalStorageBackupPayload(
                    action: .delete,
                    backupID: backupID,
                    volumes: backupVolumes,
                    expectedManifestSHA256: backup.manifestSHA256
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(deletedBackup.deleted, true)
        let deletedSnapshot: LocalStorageSnapshotResult =
            try await invoke(
                LocalStorageProviderTestRequest(
                    operation: .snapshot,
                    context: identity.context(
                        resourceGeneration: 1
                    ),
                    idempotencyKey:
                        "snapshot-delete-\(snapshotID)",
                    payload: LocalStorageSnapshotPayload(
                        action: .delete,
                        snapshotID: snapshotID,
                        expectedContentTreeSHA256:
                            snapshot.contentTreeSHA256
                    )
                ),
                dispatcher: dispatcher
            )
        XCTAssertEqual(deletedSnapshot.deleted, true)

        let expanded: LocalStorageMutationResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .expand,
                context: identity.context(
                    resourceGeneration: 2,
                    fencingToken: identity.secondFence
                ),
                idempotencyKey: "expand-\(identity.volumeID)",
                payload: LocalStorageExpandPayload(
                    capacityBytes: 2 * 1_024 * 1_024
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(expanded.volume?.generation, 2)
        XCTAssertEqual(expanded.volume?.capacityBytes, 2 * 1_024 * 1_024)

        let health: LocalStorageHealthResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .health,
                context: nil,
                idempotencyKey: "health-\(identity.volumeID)",
                payload: LocalStorageHealthPayload()
            ),
            dispatcher: dispatcher
        )
        XCTAssertTrue(health.healthy)
        XCTAssertEqual(health.volumeCount, 1)

        let invalidSnapshot = try await invokeFailure(
            LocalStorageProviderTestRequest(
                operation: .snapshot,
                context: identity.context(
                    resourceGeneration: 2,
                    fencingToken: identity.secondFence
                ),
                idempotencyKey: "unsupported-snapshot-\(identity.volumeID)",
                payload: LocalStorageUnsupportedPayload()
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(invalidSnapshot.category, .invalidRequest)
        let unchanged: LocalStorageObservation = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .observe,
                context: nil,
                idempotencyKey: "observe-after-refusal-\(identity.volumeID)",
                payload: LocalStorageObservePayload(
                    volumeID: identity.volumeID
                )
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(
            unchanged.volumes.first {
                $0.volumeID == identity.volumeID
            }?.generation,
            2
        )

        let deleted: LocalStorageMutationResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .delete,
                context: identity.context(
                    resourceGeneration: 2,
                    fencingToken: identity.secondFence
                ),
                idempotencyKey: "delete-\(identity.volumeID)",
                payload: LocalStorageDeletePayload()
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(deleted.removedVolumeID, identity.volumeID)

        let repeatedDelete: LocalStorageMutationResult = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .delete,
                context: identity.context(
                    resourceGeneration: 2,
                    fencingToken: identity.secondFence
                ),
                idempotencyKey: "delete-reordered-\(identity.volumeID)",
                payload: LocalStorageDeletePayload()
            ),
            dispatcher: dispatcher
        )
        XCTAssertEqual(
            repeatedDelete.disposition,
            .alreadySatisfied
        )
        let cleaned: LocalStorageObservation = try await invoke(
            LocalStorageProviderTestRequest(
                operation: .observe,
                context: nil,
                idempotencyKey: "observe-clean-\(identity.volumeID)",
                payload: LocalStorageObservePayload()
            ),
            dispatcher: dispatcher
        )
        XCTAssertTrue(cleaned.volumes.isEmpty)
        XCTAssertTrue(cleaned.pendingRecoveryIDs.isEmpty)
    }

    private func invoke<Payload, Result>(
        _ request: LocalStorageProviderTestRequest<Payload>,
        dispatcher: StorageProviderTransportDispatcher
    ) async throws -> Result
    where Payload: Codable & Sendable, Result: Codable & Sendable {
        let canonical = try request.canonical()
        let responseFrame = try await dispatcher.dispatch(
            frame: StorageProviderFraming.frameRequest(canonical)
        )
        let response = try StorageProviderFraming.decodeResult(responseFrame)
        if let failure = try? StorageProviderCanonicalJSON.decodeError(
            from: response
        ) {
            XCTFail(
                "Provider returned \(failure.failure.category.rawValue): "
                    + failure.failure.diagnostic
            )
            throw LocalStorageProviderError.invalidRequest
        }
        let envelope = try StorageProviderCanonicalJSON.decodeResult(
            Result.self,
            from: response
        )
        XCTAssertEqual(envelope.operation, request.operation)
        XCTAssertEqual(envelope.requestID, request.requestID)
        return envelope.result
    }

    private func invokeFailure<Payload>(
        _ request: LocalStorageProviderTestRequest<Payload>,
        dispatcher: StorageProviderTransportDispatcher
    ) async throws -> StorageProviderFailure
    where Payload: Codable & Sendable {
        let responseFrame = try await dispatcher.dispatch(
            frame: StorageProviderFraming.frameRequest(
                request.canonical()
            )
        )
        let response = try StorageProviderFraming.decodeResult(responseFrame)
        let envelope = try StorageProviderCanonicalJSON.decodeError(
            from: response
        )
        XCTAssertEqual(envelope.operation, request.operation)
        XCTAssertEqual(envelope.requestID, request.requestID)
        return envelope.failure
    }
}

private final class ForwardingStorageTestProvider:
    StorageProviderSPI,
    @unchecked Sendable
{
    private let provider: LocalStorageProvider

    init(provider: LocalStorageProvider) {
        self.provider = provider
    }

    func descriptor() async throws -> StorageProviderDescriptor {
        try await provider.descriptor()
    }

    func invoke(canonicalRequest: Data) async throws -> Data {
        try await provider.invoke(canonicalRequest: canonicalRequest)
    }

    func cancel(requestID: UUID) async {
        await provider.cancel(requestID: requestID)
    }
}

struct LocalStorageProviderTestRequest<Payload>
where Payload: Codable & Sendable {
    let requestID: UUID
    let operation: StorageProviderOperation
    let context: StorageProviderMutationContext?
    let idempotencyKey: String
    let payload: Payload

    init(
        requestID: UUID = UUID(),
        operation: StorageProviderOperation,
        context: StorageProviderMutationContext?,
        idempotencyKey: String,
        payload: Payload
    ) {
        self.requestID = requestID
        self.operation = operation
        self.context = context
        self.idempotencyKey = idempotencyKey
        self.payload = payload
    }

    func canonical(
        deadlineUnixMilliseconds: Int64 =
            Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
    ) throws -> Data {
        try StorageProviderCanonicalJSON.encodeRequest(
            StorageProviderRequest(
                requestID: requestID,
                operation: operation,
                deadlineUnixMilliseconds: deadlineUnixMilliseconds,
                capabilitySHA256:
                    try LocalStorageProviderContract.descriptor
                        .canonicalSHA256(),
                idempotencyKey: idempotencyKey,
                mutationContext: context,
                payload: payload
            )
        )
    }
}

struct LocalStorageTestIdentity {
    let projectUUID: UUID
    let resourceUUID: UUID
    let firstFence: UUID
    let secondFence: UUID

    init(
        projectUUID: UUID = UUID(),
        resourceUUID: UUID = UUID(),
        firstFence: UUID = UUID(),
        secondFence: UUID = UUID()
    ) {
        self.projectUUID = projectUUID
        self.resourceUUID = resourceUUID
        self.firstFence = firstFence
        self.secondFence = secondFence
    }

    var volumeID: String {
        resourceUUID.uuidString.lowercased()
    }

    func context(
        resourceGeneration: Int,
        attachmentGeneration: Int? = nil,
        fencingToken: UUID? = nil
    ) -> StorageProviderMutationContext {
        StorageProviderMutationContext(
            projectUUID: projectUUID,
            projectGeneration: 1,
            resourceUUID: resourceUUID,
            resourceGeneration: resourceGeneration,
            attachmentGeneration: attachmentGeneration,
            fencingToken: fencingToken ?? firstFence
        )
    }
}

private struct ConformanceBackupKeyResolver:
    StorageBackupKeyResolver
{
    func resolveKey(
        reference: HostwrightSecretReference
    ) throws -> SymmetricKey {
        SymmetricKey(
            data: Data(
                SHA256.hash(
                    data: Data(
                        "storage-provider-conformance-key".utf8
                    )
                )
            )
        )
    }
}

final class LocalStorageProviderTestHarness {
    let containerRoot: URL
    let providerRoot: URL

    init() throws {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private\(temporaryPath)"
            : temporaryPath
        containerRoot = URL(
            fileURLWithPath: canonicalTemporaryPath,
            isDirectory: true
        )
            .appendingPathComponent(
                "hostwright-local-provider-\(UUID().uuidString)",
                isDirectory: true
            )
        providerRoot = containerRoot.appendingPathComponent(
            "provider",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: containerRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: containerRoot)
    }
}
