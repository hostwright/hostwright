import Darwin
import Foundation
import HostwrightStorage
import XCTest

final class LocalStorageProviderLifecycleTests: XCTestCase {
    func testDefaultRootAndDurableOwnershipMetadataArePrivate() async throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            LocalStorageProvider.defaultRootURL(homeDirectory: home).path,
            "/Users/example/Library/Application Support/Hostwright/storage/providers/hostwright-local"
        )

        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try makeProvider(harness)
        let identity = LocalStorageTestIdentity()
        let result: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .create,
                context: identity.context(resourceGeneration: 1),
                idempotencyKey: "create-private",
                payload: LocalStorageCreatePayload(
                    name: "private-volume",
                    capacityBytes: 1_024
                )
            )
        )
        XCTAssertEqual(result.volume?.volumeID, identity.volumeID)

        let volume = harness.providerRoot
            .appendingPathComponent("volumes", isDirectory: true)
            .appendingPathComponent(identity.volumeID, isDirectory: true)
        let ownership = volume.appendingPathComponent("ownership.json")
        XCTAssertEqual(try mode(harness.providerRoot), 0o700)
        XCTAssertEqual(try mode(volume), 0o700)
        XCTAssertEqual(
            try mode(volume.appendingPathComponent("data")),
            0o700
        )
        XCTAssertEqual(try mode(ownership), 0o600)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: ownership)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            object["ownershipMarker"] as? String,
            LocalStorageProviderContract.ownershipMarker
        )
        XCTAssertEqual(object["volumeID"] as? String, identity.volumeID)
        XCTAssertEqual(
            object["projectID"] as? String,
            identity.projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(
            object["fencingToken"] as? String,
            identity.firstFence.uuidString.lowercased()
        )
    }

    func testVolumeDataSurvivesReopenAttachDetachAndReorderedCalls() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let identity = LocalStorageTestIdentity()
        var provider = try makeProvider(harness)
        let created: LocalStorageMutationResult = try await call(
            provider,
            createRequest(identity, key: "persistent-create")
        )
        let dataPath = try XCTUnwrap(created.volume?.dataPath)
        let durableFile = URL(fileURLWithPath: dataPath)
            .appendingPathComponent("durable.txt")
        try Data("survives".utf8).write(to: durableFile)

        provider = try makeProvider(harness)
        XCTAssertEqual(try provider.list().volumes.count, 1)
        XCTAssertEqual(
            try String(contentsOf: durableFile, encoding: .utf8),
            "survives"
        )

        let attachmentID = UUID().uuidString.lowercased()
        let attached: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .attach,
                context: identity.context(
                    resourceGeneration: 1,
                    attachmentGeneration: 3
                ),
                idempotencyKey: "persistent-attach",
                payload: LocalStorageAttachPayload(
                    attachmentID: attachmentID,
                    consumerID: "workload-1",
                    readOnly: false,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        identity.firstFence.uuidString.lowercased()
                )
            )
        )
        XCTAssertEqual(attached.volume?.attachments.count, 1)

        provider = try makeProvider(harness)
        let repeated: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .attach,
                context: identity.context(
                    resourceGeneration: 1,
                    attachmentGeneration: 3
                ),
                idempotencyKey: "persistent-attach-reordered",
                payload: LocalStorageAttachPayload(
                    attachmentID: attachmentID,
                    consumerID: "workload-1",
                    readOnly: false,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        identity.firstFence.uuidString.lowercased()
                )
            )
        )
        XCTAssertEqual(repeated.disposition, .alreadySatisfied)

        let detached: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .detach,
                context: identity.context(
                    resourceGeneration: 1,
                    attachmentGeneration: 3
                ),
                idempotencyKey: "persistent-detach",
                payload: LocalStorageDetachPayload(
                    attachmentID: attachmentID,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        identity.firstFence.uuidString.lowercased(),
                    expectedAttachmentGeneration: 3,
                    expectedAttachmentFencingToken:
                        identity.firstFence.uuidString.lowercased()
                )
            )
        )
        XCTAssertTrue(detached.volume?.attachments.isEmpty == true)
        XCTAssertEqual(
            try String(contentsOf: durableFile, encoding: .utf8),
            "survives"
        )
    }

    func testCapacityOwnershipGenerationFenceAndAttachmentFailuresAreClosed()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 2_048
        )
        let identity = LocalStorageTestIdentity()
        let _: LocalStorageMutationResult = try await call(
            provider,
            createRequest(
                identity,
                key: "bounded-create",
                capacity: 1_500
            )
        )

        let second = LocalStorageTestIdentity()
        let capacityFailure = try await failure(
            provider,
            createRequest(
                second,
                key: "capacity-refusal",
                capacity: 1_000
            )
        )
        XCTAssertEqual(capacityFailure.category, .rejected)

        let staleFence = UUID()
        let attachmentID = UUID().uuidString.lowercased()
        let fenceFailure = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .attach,
                context: identity.context(
                    resourceGeneration: 1,
                    attachmentGeneration: 1,
                    fencingToken: staleFence
                ),
                idempotencyKey: "stale-fence",
                payload: LocalStorageAttachPayload(
                    attachmentID: attachmentID,
                    consumerID: "workload",
                    readOnly: false,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        staleFence.uuidString.lowercased()
                )
            )
        )
        XCTAssertEqual(fenceFailure.category, .fencingConflict)

        let _: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .attach,
                context: identity.context(
                    resourceGeneration: 1,
                    attachmentGeneration: 1
                ),
                idempotencyKey: "valid-attach",
                payload: LocalStorageAttachPayload(
                    attachmentID: attachmentID,
                    consumerID: "workload",
                    readOnly: false,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        identity.firstFence.uuidString.lowercased()
                )
            )
        )
        let attachedDelete = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .delete,
                context: identity.context(resourceGeneration: 1),
                idempotencyKey: "attached-delete",
                payload: LocalStorageDeletePayload()
            )
        )
        XCTAssertEqual(attachedDelete.category, .rejected)

        let generationFailure = try await failure(
            provider,
            LocalStorageProviderTestRequest(
                operation: .expand,
                context: identity.context(
                    resourceGeneration: 3,
                    fencingToken: identity.secondFence
                ),
                idempotencyKey: "skipped-generation",
                payload: LocalStorageExpandPayload(capacityBytes: 1_700)
            )
        )
        XCTAssertEqual(generationFailure.category, .staleGeneration)
    }

    func testUnsafeModesSymlinksAndAmbiguousIdentityNeverMutateData()
        async throws
    {
        let unsafeHarness = try LocalStorageProviderTestHarness()
        defer { unsafeHarness.cleanup() }
        try FileManager.default.createDirectory(
            at: unsafeHarness.providerRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let unsafeProvider = try makeProvider(unsafeHarness)
        XCTAssertThrowsError(try unsafeProvider.list()) {
            XCTAssertEqual(
                $0 as? LocalStorageProviderError,
                .unsafePermissions
            )
        }

        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try makeProvider(harness)
        _ = try provider.list()
        let identity = LocalStorageTestIdentity()
        let volumePath = harness.providerRoot
            .appendingPathComponent("volumes", isDirectory: true)
            .appendingPathComponent(identity.volumeID, isDirectory: true)
        let external = harness.containerRoot.appendingPathComponent(
            "external",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: volumePath,
            withDestinationURL: external
        )
        let rejected = try await failure(
            provider,
            createRequest(identity, key: "symlink-create")
        )
        XCTAssertEqual(rejected.category, .ambiguousEffect)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: external.path)
        )

        let observation = try provider.list()
        XCTAssertEqual(
            observation.ambiguousVolumeIDs,
            [identity.volumeID]
        )
    }

    func testPruneRequiresExactConfirmationAndSkipsRetainedAttachedAndUnmanaged()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try makeProvider(harness)
        let removable = LocalStorageTestIdentity()
        let retained = LocalStorageTestIdentity()
        let attached = LocalStorageTestIdentity()

        let _: LocalStorageMutationResult = try await call(
            provider,
            createRequest(
                removable,
                key: "prune-removable",
                retention: .deleteWhenUnused
            )
        )
        let _: LocalStorageMutationResult = try await call(
            provider,
            createRequest(
                retained,
                key: "prune-retained",
                retention: .retain
            )
        )
        let _: LocalStorageMutationResult = try await call(
            provider,
            createRequest(
                attached,
                key: "prune-attached",
                retention: .deleteWhenUnused
            )
        )
        let attachmentID = UUID().uuidString.lowercased()
        let _: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .attach,
                context: attached.context(
                    resourceGeneration: 1,
                    attachmentGeneration: 1
                ),
                idempotencyKey: "prune-attachment",
                payload: LocalStorageAttachPayload(
                    attachmentID: attachmentID,
                    consumerID: "workload",
                    readOnly: false,
                    volumeGeneration: 1,
                    volumeFencingToken:
                        attached.firstFence.uuidString.lowercased()
                )
            )
        )
        let unmanaged = harness.providerRoot
            .appendingPathComponent("volumes", isDirectory: true)
            .appendingPathComponent("leave-me", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unmanaged,
            withIntermediateDirectories: false
        )

        let plan = try provider.prunePlan()
        XCTAssertEqual(plan.volumeIDs, [removable.volumeID])
        await XCTAssertThrowsErrorAsync(
            try await provider.prune(
                confirmationSHA256: String(repeating: "0", count: 64)
            )
        ) {
            XCTAssertEqual(
                $0 as? LocalStorageProviderError,
                .pruneConfirmationMismatch
            )
        }
        let result = try await provider.prune(
            confirmationSHA256: plan.confirmationSHA256
        )
        XCTAssertEqual(result.removedVolumeIDs, [removable.volumeID])
        XCTAssertEqual(
            Set(try provider.list().volumes.map(\.volumeID)),
            [retained.volumeID, attached.volumeID]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unmanaged.path)
        )
    }

    func testCrashRecordsResumeRepeatedCallAndExplicitRecovery() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let identity = LocalStorageTestIdentity()
        let crashState = OneShotFault(point: .afterEffectPersisted)
        var provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            faultInjector: crashState.injector
        )
        let request = createRequest(
            identity,
            key: "crash-after-effect"
        )
        await XCTAssertThrowsErrorAsync(
            try await provider.invoke(canonicalRequest: request.canonical())
        ) {
            XCTAssertEqual(
                $0 as? LocalStorageProviderInjectedInterruption,
                LocalStorageProviderInjectedInterruption(
                    point: .afterEffectPersisted
                )
            )
        }

        provider = try makeProvider(harness)
        XCTAssertEqual(try provider.list().pendingRecoveryIDs.count, 1)
        let resumed: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: request.operation,
                context: request.context,
                idempotencyKey: request.idempotencyKey,
                payload: request.payload
            )
        )
        XCTAssertEqual(resumed.volume?.volumeID, identity.volumeID)
        XCTAssertTrue(try provider.list().pendingRecoveryIDs.isEmpty)

        let secondHarness = try LocalStorageProviderTestHarness()
        defer { secondHarness.cleanup() }
        let secondIdentity = LocalStorageTestIdentity()
        let secondFault = OneShotFault(point: .afterIntentPersisted)
        var secondProvider = try LocalStorageProvider(
            rootURL: secondHarness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            faultInjector: secondFault.injector
        )
        let interrupted = createRequest(
            secondIdentity,
            key: "explicit-recovery-target"
        )
        await XCTAssertThrowsErrorAsync(
            try await secondProvider.invoke(
                canonicalRequest: interrupted.canonical()
            )
        )
        secondProvider = try makeProvider(secondHarness)
        let recovered: LocalStorageRecoveryResult = try await call(
            secondProvider,
            LocalStorageProviderTestRequest(
                operation: .recovery,
                context: secondIdentity.context(resourceGeneration: 1),
                idempotencyKey: "recover-explicit-operation",
                payload: LocalStorageRecoveryPayload(
                    idempotencyKey: interrupted.idempotencyKey
                )
            )
        )
        XCTAssertEqual(recovered.disposition, .recovered)
        XCTAssertEqual(recovered.recoveredOperation, .create)
        XCTAssertEqual(
            try secondProvider.inspect(
                volumeID: secondIdentity.volumeID
            ).volumeID,
            secondIdentity.volumeID
        )
        XCTAssertTrue(try secondProvider.list().pendingRecoveryIDs.isEmpty)
    }

    func testCancellationLeavesNoEffectAndDeleteCannotFollowDataSymlink()
        async throws
    {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try makeProvider(harness)
        let identity = LocalStorageTestIdentity()
        let request = createRequest(identity, key: "cancelled-create")
        await provider.cancel(requestID: request.requestID)
        let cancelled = try await failure(provider, request)
        XCTAssertEqual(cancelled.category, .cancelled)
        XCTAssertTrue(try provider.list().volumes.isEmpty)

        let created: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: request.operation,
                context: request.context,
                idempotencyKey: "create-after-cancellation",
                payload: request.payload
            )
        )
        let dataPath = try XCTUnwrap(created.volume?.dataPath)
        let external = harness.containerRoot.appendingPathComponent(
            "external.txt"
        )
        try Data("must-survive".utf8).write(to: external)
        let link = URL(fileURLWithPath: dataPath)
            .appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: external
        )

        let deleted: LocalStorageMutationResult = try await call(
            provider,
            LocalStorageProviderTestRequest(
                operation: .delete,
                context: identity.context(resourceGeneration: 1),
                idempotencyKey: "safe-delete",
                payload: LocalStorageDeletePayload()
            )
        )
        XCTAssertEqual(deleted.removedVolumeID, identity.volumeID)
        XCTAssertEqual(
            try String(contentsOf: external, encoding: .utf8),
            "must-survive"
        )
        XCTAssertTrue(try provider.list().volumes.isEmpty)
    }

    func testReceiptAndDeleteInterruptionsConvergeWithoutAmbiguousCleanup()
        async throws
    {
        let receiptHarness = try LocalStorageProviderTestHarness()
        defer { receiptHarness.cleanup() }
        let receiptIdentity = LocalStorageTestIdentity()
        let receiptRequest = createRequest(
            receiptIdentity,
            key: "receipt-crash"
        )
        var receiptProvider = try LocalStorageProvider(
            rootURL: receiptHarness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            faultInjector: OneShotFault(
                point: .afterReceiptPersisted
            ).injector
        )
        await XCTAssertThrowsErrorAsync(
            try await receiptProvider.invoke(
                canonicalRequest: receiptRequest.canonical()
            )
        )
        receiptProvider = try makeProvider(receiptHarness)
        XCTAssertEqual(
            try receiptProvider.list().pendingRecoveryIDs.count,
            1
        )
        let replayed: LocalStorageMutationResult = try await call(
            receiptProvider,
            LocalStorageProviderTestRequest(
                operation: receiptRequest.operation,
                context: receiptRequest.context,
                idempotencyKey: receiptRequest.idempotencyKey,
                payload: receiptRequest.payload
            )
        )
        XCTAssertEqual(replayed.volume?.volumeID, receiptIdentity.volumeID)
        XCTAssertTrue(
            try receiptProvider.list().pendingRecoveryIDs.isEmpty
        )

        let deleteHarness = try LocalStorageProviderTestHarness()
        defer { deleteHarness.cleanup() }
        let deleteIdentity = LocalStorageTestIdentity()
        var deleteProvider = try makeProvider(deleteHarness)
        let _: LocalStorageMutationResult = try await call(
            deleteProvider,
            createRequest(deleteIdentity, key: "delete-crash-create")
        )
        let deleteRequest = LocalStorageProviderTestRequest(
            operation: StorageProviderOperation.delete,
            context: deleteIdentity.context(resourceGeneration: 1),
            idempotencyKey: "delete-crash",
            payload: LocalStorageDeletePayload()
        )
        deleteProvider = try LocalStorageProvider(
            rootURL: deleteHarness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024,
            faultInjector: OneShotFault(
                point: .afterEffectPersisted
            ).injector
        )
        await XCTAssertThrowsErrorAsync(
            try await deleteProvider.invoke(
                canonicalRequest: deleteRequest.canonical()
            )
        )
        deleteProvider = try makeProvider(deleteHarness)
        XCTAssertTrue(try deleteProvider.list().volumes.isEmpty)
        XCTAssertEqual(
            try deleteProvider.list().pendingRecoveryIDs.count,
            1
        )
        let resumedDelete: LocalStorageMutationResult = try await call(
            deleteProvider,
            LocalStorageProviderTestRequest(
                operation: deleteRequest.operation,
                context: deleteRequest.context,
                idempotencyKey: deleteRequest.idempotencyKey,
                payload: deleteRequest.payload
            )
        )
        XCTAssertEqual(
            resumedDelete.disposition,
            .alreadySatisfied
        )
        XCTAssertTrue(
            try deleteProvider.list().pendingRecoveryIDs.isEmpty
        )
    }

    private func makeProvider(
        _ harness: LocalStorageProviderTestHarness
    ) throws -> LocalStorageProvider {
        try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024
        )
    }

    private func createRequest(
        _ identity: LocalStorageTestIdentity,
        key: String,
        capacity: Int64 = 1_024,
        retention: LocalStorageRetentionPolicy = .retain
    ) -> LocalStorageProviderTestRequest<LocalStorageCreatePayload> {
        LocalStorageProviderTestRequest(
            operation: .create,
            context: identity.context(resourceGeneration: 1),
            idempotencyKey: key,
            payload: LocalStorageCreatePayload(
                name: "volume-\(identity.volumeID.prefix(8))",
                capacityBytes: capacity,
                retention: retention
            )
        )
    }

    private func call<Payload, Result>(
        _ provider: LocalStorageProvider,
        _ request: LocalStorageProviderTestRequest<Payload>
    ) async throws -> Result
    where Payload: Codable & Sendable, Result: Codable & Sendable {
        let response = try await provider.invoke(
            canonicalRequest: request.canonical()
        )
        if let error = try? StorageProviderCanonicalJSON.decodeError(
            from: response
        ) {
            XCTFail(
                "Unexpected \(error.failure.category.rawValue): "
                    + error.failure.diagnostic
            )
            throw LocalStorageProviderError.invalidRequest
        }
        return try StorageProviderCanonicalJSON.decodeResult(
            Result.self,
            from: response
        ).result
    }

    private func failure<Payload>(
        _ provider: LocalStorageProvider,
        _ request: LocalStorageProviderTestRequest<Payload>
    ) async throws -> StorageProviderFailure
    where Payload: Codable & Sendable {
        let response = try await provider.invoke(
            canonicalRequest: request.canonical()
        )
        return try StorageProviderCanonicalJSON.decodeError(
            from: response
        ).failure
    }

    private func mode(_ url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        return metadata.st_mode & 0o7777
    }
}

private final class OneShotFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: LocalStorageProviderFaultPoint
    private var fired = false

    init(point: LocalStorageProviderFaultPoint) {
        self.point = point
    }

    var injector: LocalStorageProviderFaultInjector {
        LocalStorageProviderFaultInjector { [self] candidate in
            let shouldFire = lock.withLock {
                guard !fired, candidate == point else { return false }
                fired = true
                return true
            }
            if shouldFire {
                throw LocalStorageProviderInjectedInterruption(
                    point: candidate
                )
            }
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        handler(error)
    }
}
