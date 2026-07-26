import CryptoKit
import Darwin
import Foundation
import HostwrightSecrets

public final class LocalStorageProvider: StorageProviderSPI, @unchecked Sendable {
    public let rootURL: URL
    public let totalCapacityBytes: Int64

    private let faultInjector: LocalStorageProviderFaultInjector
    private let backupKeyResolver: any StorageBackupKeyResolver
    private let backupRemoteSecretStore: any SecretStore
    private let backupRemoteTransportFactory:
        any StorageBackupRemoteTransportFactory
    private let validationLock = NSLock()
    private let cancellationLock = NSLock()
    private var requestValidator: StorageProviderRequestValidator
    private var cancelledRequestIDs: Set<UUID> = []

    public static func defaultRootURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Hostwright", isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent(
                LocalStorageProviderContract.providerID,
                isDirectory: true
            )
    }

    public init(
        rootURL: URL = LocalStorageProvider.defaultRootURL(),
        totalCapacityBytes: Int64 = 1_099_511_627_776,
        faultInjector: LocalStorageProviderFaultInjector = .none,
        backupKeyResolver: any StorageBackupKeyResolver =
            StorageBackupSecretStoreKeyResolver(
                store: MacOSKeychainSecretStore()
            ),
        backupRemoteSecretStore: any SecretStore =
            MacOSKeychainSecretStore(),
        backupRemoteTransportFactory:
            any StorageBackupRemoteTransportFactory =
                StorageBackupS3TransportFactory()
    ) throws {
        self.rootURL = rootURL
        self.totalCapacityBytes = totalCapacityBytes
        self.faultInjector = faultInjector
        self.backupKeyResolver = backupKeyResolver
        self.backupRemoteSecretStore =
            backupRemoteSecretStore
        self.backupRemoteTransportFactory =
            backupRemoteTransportFactory
        requestValidator = StorageProviderRequestValidator(
            expectedCapabilitySHA256:
                try LocalStorageProviderContract.descriptor.canonicalSHA256()
        )
        guard totalCapacityBytes > 0,
              totalCapacityBytes <= StorageSemanticLimits.maximumCapacityBytes,
              rootURL.isFileURL,
              LocalStorageFilesystemSession.validAbsoluteNormalizedPath(
                  rootURL.path
              ) else {
            throw LocalStorageProviderError.invalidConfiguration
        }
    }

    public func descriptor() async throws -> StorageProviderDescriptor {
        LocalStorageProviderContract.descriptor
    }

    public func invoke(canonicalRequest: Data) async throws -> Data {
        let route = try Self.decodeRoute(canonicalRequest)
        defer { clearCancellation(requestID: route.requestID) }
        do {
            switch route.operation {
            case .create:
                return try executeMutation(
                    LocalStorageCreatePayload.self,
                    canonicalRequest: canonicalRequest,
                    apply: applyCreate
                )
            case .observe:
                return try executeObservation(canonicalRequest)
            case .attach:
                return try executeMutation(
                    LocalStorageAttachPayload.self,
                    canonicalRequest: canonicalRequest,
                    apply: applyAttach
                )
            case .detach:
                return try executeMutation(
                    LocalStorageDetachPayload.self,
                    canonicalRequest: canonicalRequest,
                    apply: applyDetach
                )
            case .snapshot:
                return try executeSnapshotRequest(
                    canonicalRequest
                )
            case .backup:
                return try executeBackupRequest(
                    canonicalRequest
                )
            case .restore:
                return try executeDetachedMutation(
                    LocalStorageRestorePayload.self,
                    canonicalRequest: canonicalRequest,
                    apply: applyRestore
                )
            case .expand:
                return try executeMutation(
                    LocalStorageExpandPayload.self,
                    canonicalRequest: canonicalRequest,
                    apply: applyExpand
                )
            case .delete:
                return try executeMutation(
                    LocalStorageDeletePayload.self,
                    canonicalRequest: canonicalRequest,
                    apply: applyDelete
                )
            case .health:
                return try executeHealth(canonicalRequest)
            case .recovery:
                return try executeDetachedMutation(
                    LocalStorageRecoveryPayload.self,
                    canonicalRequest: canonicalRequest,
                    apply: applyRecovery
                )
            }
        } catch let interruption as LocalStorageProviderInjectedInterruption {
            throw interruption
        } catch {
            return try StorageProviderCanonicalJSON.encodeError(
                StorageProviderErrorEnvelope(
                    requestID: route.requestID,
                    operation: route.operation,
                    failure: Self.failure(for: error)
                )
            )
        }
    }

    public func cancel(requestID: UUID) async {
        _ = cancellationLock.withLock {
            cancelledRequestIDs.insert(requestID)
        }
    }

    public func list() throws -> LocalStorageObservation {
        let session = try makeSession()
        return try observation(session: session, volumeID: nil)
    }

    public func inspect(volumeID: String) throws
        -> LocalStorageVolumeObservation
    {
        let session = try makeSession()
        let metadata = try session.loadVolume(volumeID: volumeID)
        return try session.observe(metadata)
    }

    public func prunePlan() throws -> LocalStoragePrunePlan {
        let session = try makeSession()
        let scan = try session.scanVolumes()
        let candidates = scan.volumes.filter {
            $0.0.retention == .deleteWhenUnused &&
                $0.0.attachments.isEmpty
        }
        let capacity = candidates.reduce(Int64(0)) {
            let (sum, overflow) = $0.addingReportingOverflow(
                $1.0.capacityBytes
            )
            return overflow ? Int64.max : sum
        }
        return LocalStoragePrunePlan(
            volumeIDs: candidates.map(\.0.volumeID),
            reclaimedCapacityBytes: capacity
        )
    }

    public func prune(
        confirmationSHA256: String
    ) async throws -> LocalStoragePruneResult {
        let plan = try prunePlan()
        guard plan.confirmationSHA256 == confirmationSHA256 else {
            throw LocalStorageProviderError.pruneConfirmationMismatch
        }
        var removed: [String] = []
        var reclaimed: Int64 = 0
        for volumeID in plan.volumeIDs {
            let metadata = try makeSession().loadVolume(volumeID: volumeID)
            guard metadata.retention == .deleteWhenUnused,
                  metadata.attachments.isEmpty else {
                throw LocalStorageProviderError.pruneConfirmationMismatch
            }
            let context = StorageProviderMutationContext(
                projectUUID: UUID(uuidString: metadata.projectID)!,
                projectGeneration: metadata.projectGeneration,
                resourceUUID: UUID(uuidString: metadata.volumeID)!,
                resourceGeneration: metadata.generation,
                fencingToken: UUID(uuidString: metadata.fencingToken)!
            )
            let request = StorageProviderRequest(
                operation: .delete,
                deadlineUnixMilliseconds:
                    Int64(Date().timeIntervalSince1970 * 1_000) + 60_000,
                capabilitySHA256:
                    try LocalStorageProviderContract.descriptor
                        .canonicalSHA256(),
                idempotencyKey:
                    "prune-\(confirmationSHA256)-\(metadata.volumeID)",
                mutationContext: context,
                payload: LocalStorageDeletePayload()
            )
            let response = try await invoke(
                canonicalRequest:
                    StorageProviderCanonicalJSON.encodeRequest(request)
            )
            do {
                let result = try StorageProviderCanonicalJSON.decodeResult(
                    LocalStorageMutationResult.self,
                    from: response
                )
                guard result.result.removedVolumeID == metadata.volumeID else {
                    throw LocalStorageProviderError.ambiguousVolume
                }
            } catch {
                if (try? StorageProviderCanonicalJSON.decodeError(
                    from: response
                )) != nil {
                    throw LocalStorageProviderError.ambiguousVolume
                }
                throw error
            }
            removed.append(metadata.volumeID)
            let (sum, overflow) = reclaimed.addingReportingOverflow(
                metadata.capacityBytes
            )
            reclaimed = overflow ? Int64.max : sum
        }
        return LocalStoragePruneResult(
            removedVolumeIDs: removed,
            reclaimedCapacityBytes: reclaimed
        )
    }

    private func executeObservation(_ canonicalRequest: Data) throws -> Data {
        let request = try StorageProviderCanonicalJSON.decodeRequest(
            LocalStorageObservePayload.self,
            from: canonicalRequest
        )
        try validate(request)
        if let volumeID = request.payload.volumeID,
           !LocalStorageFilesystemSession.validCanonicalUUID(volumeID) {
            throw LocalStorageProviderError.invalidRequest
        }
        let result = try observation(
            session: makeSession(),
            volumeID: request.payload.volumeID
        )
        return try StorageProviderCanonicalJSON.encodeResult(
            StorageProviderResultEnvelope(
                requestID: request.requestID,
                operation: request.operation,
                result: result
            )
        )
    }

    private func executeHealth(_ canonicalRequest: Data) throws -> Data {
        let request = try StorageProviderCanonicalJSON.decodeRequest(
            LocalStorageHealthPayload.self,
            from: canonicalRequest
        )
        try validate(request)
        let session = try makeSession()
        let scan = try session.scanVolumes()
        let pending = try session.pendingRecoveryIDs()
        let reserved = try reservedCapacity(scan)
        var issues = scan.unmanagedEntries.map {
            "unmanaged-entry:\($0)"
        }
        issues.append(contentsOf: scan.ambiguousVolumeIDs.map {
            "ambiguous-volume:\($0)"
        })
        issues.append(contentsOf: pending.map {
            "pending-recovery:\($0)"
        })
        let result = LocalStorageHealthResult(
            issues: issues,
            volumeCount: scan.volumes.count,
            pendingRecoveryCount: pending.count,
            totalCapacityBytes: totalCapacityBytes,
            availableCapacityBytes: max(0, totalCapacityBytes - reserved)
        )
        return try StorageProviderCanonicalJSON.encodeResult(
            StorageProviderResultEnvelope(
                requestID: request.requestID,
                operation: request.operation,
                result: result
            )
        )
    }

    private func executeSnapshotRequest(
        _ canonicalRequest: Data
    ) throws -> Data {
        let request = try StorageProviderCanonicalJSON
            .decodeRequest(
                LocalStorageSnapshotPayload.self,
                from: canonicalRequest
            )
        guard request.payload.action == .verify else {
            return try executeDetachedMutation(
                LocalStorageSnapshotPayload.self,
                canonicalRequest: canonicalRequest,
                apply: applySnapshot
            )
        }
        try validate(request)
        guard request.mutationContext != nil else {
            throw LocalStorageProviderError.invalidRequest
        }
        try checkCancellation(requestID: request.requestID)
        let result = try applySnapshot(request, false)
        try checkCancellation(requestID: request.requestID)
        return try StorageProviderCanonicalJSON.encodeResult(
            StorageProviderResultEnvelope(
                requestID: request.requestID,
                operation: request.operation,
                result: result
            )
        )
    }

    private func executeBackupRequest(
        _ canonicalRequest: Data
    ) throws -> Data {
        let request = try StorageProviderCanonicalJSON
            .decodeRequest(
                LocalStorageBackupPayload.self,
                from: canonicalRequest
            )
        guard request.payload.action == .verify else {
            return try executeDetachedMutation(
                LocalStorageBackupPayload.self,
                canonicalRequest: canonicalRequest,
                apply: applyBackup
            )
        }
        try validate(request)
        guard request.mutationContext != nil else {
            throw LocalStorageProviderError.invalidRequest
        }
        try checkCancellation(requestID: request.requestID)
        let result = try applyBackup(request, false)
        try checkCancellation(requestID: request.requestID)
        return try StorageProviderCanonicalJSON.encodeResult(
            StorageProviderResultEnvelope(
                requestID: request.requestID,
                operation: request.operation,
                result: result
            )
        )
    }

    private func executeMutation<
        Payload: Codable & Sendable,
        Result: Codable & Sendable
    >(
        _ payloadType: Payload.Type,
        canonicalRequest: Data,
        apply: (
            StorageProviderRequest<Payload>,
            LocalStorageFilesystemSession
        ) throws -> Result
    ) throws -> Data {
        let request = try StorageProviderCanonicalJSON.decodeRequest(
            payloadType,
            from: canonicalRequest
        )
        try validate(request)
        guard let context = request.mutationContext else {
            throw LocalStorageProviderError.invalidRequest
        }
        try checkCancellation(requestID: request.requestID)
        let session = try makeSession()
        let keySHA256 = Self.sha256(Data(request.idempotencyKey.utf8))
        let requestSHA256 = try Self.stableRequestSHA256(canonicalRequest)

        if let receipt = try session.loadReceipt(keySHA256: keySHA256) {
            guard receipt.requestSHA256 == requestSHA256,
                  receipt.idempotencyKeySHA256 == keySHA256,
                  receipt.operation == request.operation else {
                throw LocalStorageProviderError.idempotencyConflict
            }
            try session.removeIntent(keySHA256: keySHA256)
            let result: Result = try Self.decodeCanonical(
                Result.self,
                data: receipt.canonicalResult
            )
            return try StorageProviderCanonicalJSON.encodeResult(
                StorageProviderResultEnvelope(
                    requestID: request.requestID,
                    operation: request.operation,
                    result: result
                )
            )
        }

        if let intent = try session.loadIntent(keySHA256: keySHA256) {
            guard intent.idempotencyKeySHA256 == keySHA256,
                  intent.requestSHA256 == requestSHA256,
                  intent.operation == request.operation,
                  intent.context == context else {
                throw LocalStorageProviderError.idempotencyConflict
            }
        } else {
            try session.writeIntent(
                LocalStorageMutationIntent(
                    idempotencyKeySHA256: keySHA256,
                    requestSHA256: requestSHA256,
                    canonicalRequest: canonicalRequest,
                    operation: request.operation,
                    requestID: request.requestID,
                    context: context
                )
            )
        }

        var effectPersisted = false
        do {
            try faultInjector.inject(.afterIntentPersisted)
            try checkCancellation(requestID: request.requestID)
            let result = try apply(request, session)
            effectPersisted = true
            let canonicalResult = try Self.encodeCanonical(result)
            try faultInjector.inject(.afterEffectPersisted)
            try checkCancellation(requestID: request.requestID)
            try session.writeReceipt(
                LocalStorageMutationReceipt(
                    idempotencyKeySHA256: keySHA256,
                    requestSHA256: requestSHA256,
                    operation: request.operation,
                    requestID: request.requestID,
                    canonicalResult: canonicalResult
                )
            )
            try faultInjector.inject(.afterReceiptPersisted)
            try session.removeIntent(keySHA256: keySHA256)
            return try StorageProviderCanonicalJSON.encodeResult(
                StorageProviderResultEnvelope(
                    requestID: request.requestID,
                    operation: request.operation,
                    result: result
                )
            )
        } catch let interruption as LocalStorageProviderInjectedInterruption {
            throw interruption
        } catch {
            if !effectPersisted, !Self.requiresRecovery(error) {
                try? session.removeIntent(keySHA256: keySHA256)
            }
            throw error
        }
    }

    private func executeDetachedMutation<
        Payload: Codable & Sendable,
        Result: Codable & Sendable
    >(
        _ payloadType: Payload.Type,
        canonicalRequest: Data,
        apply: (
            StorageProviderRequest<Payload>,
            Bool
        ) throws -> Result
    ) throws -> Data {
        let request = try StorageProviderCanonicalJSON.decodeRequest(
            payloadType,
            from: canonicalRequest
        )
        try validate(request)
        guard let context = request.mutationContext else {
            throw LocalStorageProviderError.invalidRequest
        }
        try checkCancellation(requestID: request.requestID)
        let keySHA256 = Self.sha256(
            Data(request.idempotencyKey.utf8)
        )
        let requestSHA256 =
            try Self.stableRequestSHA256(canonicalRequest)

        var replayingIntent = false
        do {
            let session = try makeSession()
            if let receipt = try session.loadReceipt(
                keySHA256: keySHA256
            ) {
                guard receipt.requestSHA256 == requestSHA256,
                      receipt.idempotencyKeySHA256 == keySHA256,
                      receipt.operation == request.operation else {
                    throw LocalStorageProviderError
                        .idempotencyConflict
                }
                try session.removeIntent(keySHA256: keySHA256)
                let result: Result = try Self.decodeCanonical(
                    Result.self,
                    data: receipt.canonicalResult
                )
                return try StorageProviderCanonicalJSON
                    .encodeResult(
                        StorageProviderResultEnvelope(
                            requestID: request.requestID,
                            operation: request.operation,
                            result: result
                        )
                    )
            }
            if let intent = try session.loadIntent(
                keySHA256: keySHA256
            ) {
                guard intent.idempotencyKeySHA256 == keySHA256,
                      intent.requestSHA256 == requestSHA256,
                      intent.operation == request.operation,
                      intent.context == context else {
                    throw LocalStorageProviderError
                        .idempotencyConflict
                }
                replayingIntent = true
            } else {
                try session.writeIntent(
                    LocalStorageMutationIntent(
                        idempotencyKeySHA256: keySHA256,
                        requestSHA256: requestSHA256,
                        canonicalRequest: canonicalRequest,
                        operation: request.operation,
                        requestID: request.requestID,
                        context: context
                    )
                )
            }
        }

        var effectPersisted = false
        do {
            try faultInjector.inject(.afterIntentPersisted)
            try checkCancellation(requestID: request.requestID)
            let result = try apply(request, replayingIntent)
            effectPersisted = true
            let canonicalResult = try Self.encodeCanonical(result)
            try faultInjector.inject(.afterEffectPersisted)
            try checkCancellation(requestID: request.requestID)
            do {
                let session = try makeSession()
                try session.writeReceipt(
                    LocalStorageMutationReceipt(
                        idempotencyKeySHA256: keySHA256,
                        requestSHA256: requestSHA256,
                        operation: request.operation,
                        requestID: request.requestID,
                        canonicalResult: canonicalResult
                    )
                )
                try faultInjector.inject(.afterReceiptPersisted)
                try session.removeIntent(keySHA256: keySHA256)
            }
            return try StorageProviderCanonicalJSON.encodeResult(
                StorageProviderResultEnvelope(
                    requestID: request.requestID,
                    operation: request.operation,
                    result: result
                )
            )
        } catch let interruption as
            LocalStorageProviderInjectedInterruption
        {
            throw interruption
        } catch {
            if !effectPersisted, !Self.requiresRecovery(error) {
                try? makeSession().removeIntent(
                    keySHA256: keySHA256
                )
            }
            throw error
        }
    }

    private func applyCreate(
        _ request: StorageProviderRequest<LocalStorageCreatePayload>,
        _ session: LocalStorageFilesystemSession
    ) throws -> LocalStorageMutationResult {
        guard let context = request.mutationContext,
              context.resourceGeneration > 0,
              LocalStorageFilesystemSession.validName(request.payload.name),
              request.payload.capacityBytes > 0,
              request.payload.capacityBytes <= totalCapacityBytes else {
            throw LocalStorageProviderError.invalidRequest
        }
        let volumeID = context.resourceUUID.uuidString.lowercased()
        let scan = try session.scanVolumes()
        if !scan.ambiguousVolumeIDs.isEmpty {
            throw LocalStorageProviderError.ambiguousVolume
        }
        if scan.volumes.contains(where: {
            $0.0.name == request.payload.name &&
                $0.0.volumeID != volumeID
        }) {
            throw LocalStorageProviderError.nameCollision
        }
        if !scan.volumes.contains(where: { $0.0.volumeID == volumeID }) {
            guard scan.volumes.count <
                    LocalStorageProviderContract.maximumVolumes else {
                throw LocalStorageProviderError.volumeLimitExceeded
            }
            let reserved = try reservedCapacity(scan)
            let filesystemAvailable = try session.filesystemAvailableBytes()
            guard request.payload.capacityBytes <=
                    totalCapacityBytes - reserved,
                  request.payload.capacityBytes <=
                    filesystemAvailable else {
                throw LocalStorageProviderError.capacityExceeded
            }
        }
        let metadata = LocalStorageVolumeMetadata(
            volumeID: volumeID,
            name: request.payload.name,
            projectID: context.projectUUID.uuidString.lowercased(),
            projectGeneration: context.projectGeneration,
            generation: context.resourceGeneration,
            fencingToken: context.fencingToken.uuidString.lowercased(),
            capacityBytes: request.payload.capacityBytes,
            retention: request.payload.retention
        )
        let disposition = try session.createVolume(metadata)
        return LocalStorageMutationResult(
            disposition: disposition,
            volume: try session.observe(metadata)
        )
    }

    private func applyAttach(
        _ request: StorageProviderRequest<LocalStorageAttachPayload>,
        _ session: LocalStorageFilesystemSession
    ) throws -> LocalStorageMutationResult {
        guard let context = request.mutationContext,
              let attachmentGeneration =
                context.attachmentGeneration,
              LocalStorageFilesystemSession.validCanonicalUUID(
                  request.payload.attachmentID
              ),
              LocalStorageFilesystemSession.validName(
                  request.payload.consumerID
              ),
              request.payload.volumeGeneration > 0,
              LocalStorageFilesystemSession.validCanonicalUUID(
                  request.payload.volumeFencingToken
              ) else {
            throw LocalStorageProviderError.invalidRequest
        }
        let metadata = try attachmentOwnedVolume(
            context: context,
            volumeGeneration: request.payload.volumeGeneration,
            volumeFencingToken:
                request.payload.volumeFencingToken,
            session: session
        )
        let attachment = LocalStorageAttachmentMetadata(
            attachmentID: request.payload.attachmentID,
            consumerID: request.payload.consumerID,
            generation: attachmentGeneration,
            fencingToken:
                context.fencingToken.uuidString.lowercased(),
            readOnly: request.payload.readOnly
        )
        if let existing = metadata.attachments.first(where: {
            $0.attachmentID == attachment.attachmentID
        }) {
            guard existing == attachment else {
                throw LocalStorageProviderError.attachmentConflict
            }
            return LocalStorageMutationResult(
                disposition: .alreadySatisfied,
                volume: try session.observe(metadata)
            )
        }
        guard metadata.attachments.count <
                LocalStorageProviderContract.maximumAttachmentsPerVolume else {
            throw LocalStorageProviderError.attachmentLimitExceeded
        }
        let updated = replacing(
            metadata,
            attachments: metadata.attachments + [attachment]
        )
        try session.writeVolume(updated)
        return LocalStorageMutationResult(
            disposition: .performed,
            volume: try session.observe(updated)
        )
    }

    private func applyDetach(
        _ request: StorageProviderRequest<LocalStorageDetachPayload>,
        _ session: LocalStorageFilesystemSession
    ) throws -> LocalStorageMutationResult {
        guard let context = request.mutationContext,
              context.attachmentGeneration != nil,
              LocalStorageFilesystemSession.validCanonicalUUID(
                  request.payload.attachmentID
              ),
              request.payload.volumeGeneration > 0,
              request.payload.expectedAttachmentGeneration > 0,
              LocalStorageFilesystemSession.validCanonicalUUID(
                  request.payload.volumeFencingToken
              ),
              LocalStorageFilesystemSession.validCanonicalUUID(
                  request.payload.expectedAttachmentFencingToken
              ) else {
            throw LocalStorageProviderError.invalidRequest
        }
        let metadata = try attachmentOwnedVolume(
            context: context,
            volumeGeneration: request.payload.volumeGeneration,
            volumeFencingToken:
                request.payload.volumeFencingToken,
            session: session
        )
        guard let existing = metadata.attachments.first(where: {
            $0.attachmentID == request.payload.attachmentID
        }) else {
            return LocalStorageMutationResult(
                disposition: .alreadySatisfied,
                volume: try session.observe(metadata)
            )
        }
        guard existing.generation ==
                request.payload.expectedAttachmentGeneration else {
            throw LocalStorageProviderError.generationMismatch
        }
        guard existing.fencingToken ==
                request.payload.expectedAttachmentFencingToken else {
            throw LocalStorageProviderError.fencingConflict
        }
        let updated = replacing(
            metadata,
            attachments: metadata.attachments.filter {
                $0.attachmentID != existing.attachmentID
            }
        )
        try session.writeVolume(updated)
        return LocalStorageMutationResult(
            disposition: .performed,
            volume: try session.observe(updated)
        )
    }

    private func applySnapshot(
        _ request:
            StorageProviderRequest<LocalStorageSnapshotPayload>,
        _ replayingIntent: Bool
    ) throws -> LocalStorageSnapshotResult {
        guard let context = request.mutationContext,
              LocalStorageFilesystemSession.validCanonicalUUID(
                  request.payload.snapshotID
              ) else {
            throw LocalStorageProviderError.invalidRequest
        }
        let action = request.payload.action ?? .create
        let volume = try ownedObservation(context: context)
        let engine = try makeSnapshotEngine()
        let hooks = StorageSnapshotHooks(
            isCancelled: { [weak self] in
                self?.cancellationRequested(
                    requestID: request.requestID
                ) ?? true
            }
        )

        switch action {
        case .create:
            guard let name = request.payload.name,
                  let consistency = request.payload.consistency,
                  LocalStorageFilesystemSession.validName(name),
                  consistency == .crashConsistent,
                  request.payload.retainerID == nil,
                  request.payload.destinationPath == nil,
                  request.payload.expectedContentTreeSHA256 ==
                    nil else {
                throw LocalStorageProviderError.invalidRequest
            }
            do {
                let existing = try engine.verify(
                    snapshotID: request.payload.snapshotID,
                    hooks: hooks
                )
                guard existing.name == name,
                      existing.consistencyClass == consistency,
                      snapshotSourceMatches(
                          existing.source,
                          volume: volume
                      ) else {
                    throw LocalStorageProviderError
                        .dataProtectionConflict
                }
                return snapshotResult(
                    existing,
                    disposition: .alreadySatisfied
                )
            } catch StorageSnapshotError.snapshotNotFound {
                do {
                    let created = try engine.create(
                        snapshotID: request.payload.snapshotID,
                        name: name,
                        volumeID: volume.volumeID,
                        expectedGeneration: volume.generation,
                        expectedFencingToken:
                            volume.fencingToken,
                        consistency: consistency,
                        hooks: hooks
                    )
                    let verified = try engine.verify(
                        snapshotID: created.snapshotID,
                        hooks: hooks
                    )
                    return snapshotResult(
                        verified,
                        disposition: .performed
                    )
                } catch {
                    throw Self.normalizeDataProtection(error)
                }
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        case .verify:
            guard let expectedDigest =
                    request.payload
                        .expectedContentTreeSHA256,
                  Self.validSHA256(expectedDigest),
                  request.payload.name == nil,
                  request.payload.consistency == nil,
                  request.payload.retainerID == nil,
                  request.payload.destinationPath == nil else {
                throw LocalStorageProviderError.invalidRequest
            }
            do {
                let existing = try engine.verify(
                    snapshotID: request.payload.snapshotID,
                    hooks: hooks
                )
                try validateSnapshotOwnership(
                    existing,
                    volume: volume
                )
                guard existing.snapshotContentTreeSHA256 ==
                        expectedDigest else {
                    throw LocalStorageProviderError
                        .dataProtectionConflict
                }
                return snapshotResult(
                    existing,
                    disposition: .performed,
                    action: .verify
                )
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        case .retain:
            guard let retainerID = request.payload.retainerID,
                  LocalStorageFilesystemSession.validName(
                      retainerID
                  ),
                  request.payload.name == nil,
                  request.payload.consistency == nil,
                  request.payload.destinationPath == nil,
                  request.payload.expectedContentTreeSHA256 ==
                    nil else {
                throw LocalStorageProviderError.invalidRequest
            }
            do {
                let existing = try engine.verify(
                    snapshotID: request.payload.snapshotID,
                    hooks: hooks
                )
                try validateSnapshotOwnership(
                    existing,
                    volume: volume
                )
                let alreadyRetained =
                    existing.retainedBy.contains(retainerID)
                try checkCancellation(
                    requestID: request.requestID
                )
                let retained = try engine.retain(
                    snapshotID: existing.snapshotID,
                    retainerID: retainerID
                )
                return snapshotResult(
                    retained,
                    disposition: alreadyRetained
                        ? .alreadySatisfied : .performed,
                    action: .retain,
                    retainedBy: retained.retainedBy
                )
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        case .export:
            guard let destinationPath =
                    request.payload.destinationPath,
                  let expectedDigest =
                    request.payload
                        .expectedContentTreeSHA256,
                  Self.validSHA256(expectedDigest),
                  destinationPath.utf8.count <=
                    StorageSemanticLimits.maximumPathBytes,
                  LocalStorageFilesystemSession
                    .validAbsoluteNormalizedPath(
                        destinationPath
                    ),
                  request.payload.name == nil,
                  request.payload.consistency == nil,
                  request.payload.retainerID == nil else {
                throw LocalStorageProviderError.invalidRequest
            }
            do {
                let existing = try engine.verify(
                    snapshotID: request.payload.snapshotID,
                    hooks: hooks
                )
                try validateSnapshotOwnership(
                    existing,
                    volume: volume
                )
                guard existing.snapshotContentTreeSHA256 ==
                        expectedDigest else {
                    throw LocalStorageProviderError
                        .dataProtectionConflict
                }
                let destination = URL(
                    fileURLWithPath: destinationPath,
                    isDirectory: true
                )
                try checkCancellation(
                    requestID: request.requestID
                )
                do {
                    try engine.exportSnapshot(
                        snapshotID: existing.snapshotID,
                        to: destination,
                        hooks: hooks
                    )
                    return snapshotResult(
                        existing,
                        disposition: .performed,
                        action: .export,
                        exportedPath: destinationPath
                    )
                } catch StorageSnapshotError
                    .destinationExists
                    where replayingIntent {
                    try verifySnapshotExport(
                        existing,
                        at: destination,
                        hooks: hooks
                    )
                    return snapshotResult(
                        existing,
                        disposition: .alreadySatisfied,
                        action: .export,
                        exportedPath: destinationPath
                    )
                }
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        case .delete:
            guard let expectedDigest =
                    request.payload
                        .expectedContentTreeSHA256,
                  Self.validSHA256(expectedDigest),
                  request.payload.name == nil,
                  request.payload.consistency == nil,
                  request.payload.retainerID == nil,
                  request.payload.destinationPath == nil else {
                throw LocalStorageProviderError.invalidRequest
            }
            do {
                let existing = try engine.verify(
                    snapshotID: request.payload.snapshotID,
                    hooks: hooks
                )
                try validateSnapshotOwnership(
                    existing,
                    volume: volume
                )
                guard existing.snapshotContentTreeSHA256 ==
                        expectedDigest else {
                    throw LocalStorageProviderError
                        .dataProtectionConflict
                }
                try checkCancellation(
                    requestID: request.requestID
                )
                try engine.delete(
                    snapshotID: existing.snapshotID
                )
                try? removeSupersededSnapshotIntents(
                    session: makeSession(),
                    context: context,
                    snapshotID: existing.snapshotID,
                    excludingIdempotencyKey: request.idempotencyKey
                )
                return snapshotResult(
                    existing,
                    disposition: .performed,
                    action: .delete,
                    deleted: true
                )
            } catch StorageSnapshotError.snapshotNotFound
                where replayingIntent {
                return LocalStorageSnapshotResult(
                    disposition: .alreadySatisfied,
                    snapshotID: request.payload.snapshotID,
                    sourceVolumeID: volume.volumeID,
                    sourceGeneration: volume.generation,
                    sourceFencingToken: volume.fencingToken,
                    consistencyClass: .crashConsistent,
                    parentContentTreeSHA256: expectedDigest,
                    contentTreeSHA256: expectedDigest,
                    lineage: [
                        "volume:\(volume.volumeID)@\(volume.generation)"
                    ],
                    action: .delete,
                    deleted: true
                )
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        }
    }

    private func removeSupersededSnapshotIntents(
        session: LocalStorageFilesystemSession,
        context: StorageProviderMutationContext,
        snapshotID: String,
        excludingIdempotencyKey currentIdempotencyKey: String
    ) throws {
        let currentKeySHA256 = Self.sha256(
            Data(currentIdempotencyKey.utf8)
        )
        for keySHA256 in try session.pendingRecoveryIDs()
        where keySHA256 != currentKeySHA256 {
            guard let intent = try session.loadIntent(
                keySHA256: keySHA256
            ),
            intent.operation == .snapshot,
            intent.context == context else {
                continue
            }
            let request = try StorageProviderCanonicalJSON
                .decodeRequest(
                    LocalStorageSnapshotPayload.self,
                    from: intent.canonicalRequest
                )
            guard request.payload.snapshotID == snapshotID else {
                continue
            }
            try session.removeIntent(keySHA256: keySHA256)
        }
    }

    private func applyBackup(
        _ request:
            StorageProviderRequest<LocalStorageBackupPayload>,
        _ replayingIntent: Bool
    ) throws -> LocalStorageBackupResult {
        guard let context = request.mutationContext,
              LocalStorageFilesystemSession.validCanonicalUUID(
                  request.payload.backupID
              ),
              !request.payload.volumes.isEmpty,
              request.payload.volumes.count <=
                LocalStorageProviderContract
                    .maximumDataProtectionVolumes,
              request.payload.volumes ==
                request.payload.volumes.sorted(by: {
                    $0.volumeID < $1.volumeID
                }),
              Set(request.payload.volumes.map(\.volumeID)).count ==
                request.payload.volumes.count else {
            throw LocalStorageProviderError.invalidRequest
        }
        let action = request.payload.action ?? .create
        let volumes = try request.payload.volumes.map {
            try validatedBackupVolume(
                $0,
                projectUUID: context.projectUUID,
                projectGeneration: context.projectGeneration
            )
        }
        guard volumes.contains(where: {
            $0.volumeID ==
                context.resourceUUID.uuidString.lowercased() &&
                $0.generation == context.resourceGeneration &&
                $0.fencingToken ==
                    context.fencingToken.uuidString.lowercased()
        }) else {
            throw LocalStorageProviderError.ownershipMismatch
        }

        switch action {
        case .create:
            guard let name = request.payload.name,
                  let keyReferenceText =
                    request.payload.keyReference,
                  LocalStorageFilesystemSession.validName(name),
                  request.payload.retainerID == nil,
                  request.payload.expectedManifestSHA256 == nil else {
                throw LocalStorageProviderError.invalidRequest
            }
            let keyReference =
                try parseBackupKeyReference(keyReferenceText)
            let engine = try makeBackupEngine(
                keyReference: keyReference,
                remoteDestination:
                    request.payload.remoteDestination
            )
            let hooks = StorageBackupHooks(
                isCancelled: { [weak self] in
                    self?.cancellationRequested(
                        requestID: request.requestID
                    ) ?? true
                }
            )
            do {
                let existing = try engine.inspect(
                    backupID: request.payload.backupID
                )
                try validateBackupRecord(
                    existing,
                    name: name,
                    keyReference: keyReference,
                    volumes: volumes,
                    remoteDestination:
                        request.payload.remoteDestination,
                    projectUUID: context.projectUUID,
                    projectGeneration: context.projectGeneration
                )
                let verified = try engine.verify(
                    backupID: existing.backupID
                )
                return backupResult(
                    verified,
                    disposition: .alreadySatisfied
                )
            } catch StorageBackupError.backupNotFound {
                do {
                    let created = try engine.createBackup(
                        backupID: request.payload.backupID,
                        name: name,
                        volumes: volumes.map {
                            StorageBackupVolumeRequest(
                                volumeID: $0.volumeID,
                                expectedGeneration: $0.generation,
                                expectedFencingToken:
                                    $0.fencingToken
                            )
                        },
                        hooks: hooks
                    )
                    let verified = try engine.verify(
                        backupID: created.backupID
                    )
                    return backupResult(
                        verified,
                        disposition: .performed
                    )
                } catch {
                    throw Self.normalizeDataProtection(error)
                }
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        case .verify:
            guard request.payload.name == nil,
                  request.payload.retainerID == nil else {
                throw LocalStorageProviderError.invalidRequest
            }
            do {
                try checkCancellation(
                    requestID: request.requestID
                )
                let backup: StorageBackupRecord
                let verifiedVolumeIDs: [String]
                let requiresExactVolumeSet: Bool
                if let keyReferenceText =
                    request.payload.keyReference {
                    let keyReference =
                        try parseBackupKeyReference(
                            keyReferenceText
                        )
                    let verified = try makeBackupEngine(
                        keyReference: keyReference,
                        remoteDestination:
                            try resolvedBackupRemoteDestination(
                                requested:
                                    request.payload
                                        .remoteDestination,
                                backupID:
                                    request.payload.backupID
                            )
                    ).verify(
                        backupID: request.payload.backupID
                    )
                    backup = verified.backup
                    verifiedVolumeIDs =
                        verified.verifiedVolumeIDs
                    requiresExactVolumeSet = true
                } else {
                    guard let expected =
                            request.payload
                                .expectedManifestSHA256,
                          Self.validSHA256(expected) else {
                        throw LocalStorageProviderError
                            .invalidRequest
                    }
                    backup = try makeBackupEngine(
                        keyReference: nil,
                        remoteDestination:
                            try resolvedBackupRemoteDestination(
                                requested:
                                    request.payload
                                        .remoteDestination,
                                backupID:
                                    request.payload.backupID
                            )
                    ).verifyStoredArtifact(
                        backupID: request.payload.backupID,
                        expectedManifestSHA256: expected
                    )
                    verifiedVolumeIDs =
                        backup.volumes.map {
                            $0.source.volumeID
                        }
                    requiresExactVolumeSet = false
                }
                if requiresExactVolumeSet {
                    try validateBackupOwnership(
                        backup,
                        volumes: volumes,
                        projectUUID: context.projectUUID,
                        projectGeneration:
                            context.projectGeneration
                    )
                } else {
                    try validateBackupContainsOwnership(
                        backup,
                        volumes: volumes,
                        projectUUID: context.projectUUID,
                        projectGeneration:
                            context.projectGeneration
                    )
                }
                try validateExpectedManifest(
                    request.payload.expectedManifestSHA256,
                    backup: backup
                )
                try checkCancellation(
                    requestID: request.requestID
                )
                return LocalStorageBackupResult(
                    disposition: .performed,
                    backupID: backup.backupID,
                    manifestSHA256:
                        backup.manifestSHA256,
                    verifiedVolumeIDs:
                        verifiedVolumeIDs,
                    action: .verify
                )
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        case .retain:
            guard request.payload.name == nil,
                  request.payload.keyReference == nil,
                  let retainerID = request.payload.retainerID,
                  LocalStorageFilesystemSession.validName(
                      retainerID
                  ) else {
                throw LocalStorageProviderError.invalidRequest
            }
            let engine = try makeBackupEngine(
                keyReference: nil,
                remoteDestination:
                    try resolvedBackupRemoteDestination(
                        requested:
                            request.payload.remoteDestination,
                        backupID:
                            request.payload.backupID
                    )
            )
            do {
                let existing = try engine.inspect(
                    backupID: request.payload.backupID
                )
                try validateBackupOwnership(
                    existing,
                    volumes: volumes,
                    projectUUID: context.projectUUID,
                    projectGeneration: context.projectGeneration
                )
                let alreadyRetained =
                    existing.retainedBy.contains(retainerID)
                if !alreadyRetained {
                    try validateExpectedManifest(
                        request.payload
                            .expectedManifestSHA256,
                        backup: existing
                    )
                }
                try checkCancellation(
                    requestID: request.requestID
                )
                let retained = try engine.retain(
                    backupID: existing.backupID,
                    retainerID: retainerID
                )
                return LocalStorageBackupResult(
                    disposition: alreadyRetained
                        ? .alreadySatisfied : .performed,
                    backupID: retained.backupID,
                    manifestSHA256:
                        retained.manifestSHA256,
                    verifiedVolumeIDs:
                        retained.volumes.map {
                            $0.source.volumeID
                        },
                    action: .retain,
                    retainedBy: retained.retainedBy
                )
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        case .delete:
            guard request.payload.name == nil,
                  request.payload.keyReference == nil,
                  request.payload.retainerID == nil,
                  let expectedManifest =
                    request.payload
                        .expectedManifestSHA256,
                  Self.validSHA256(expectedManifest) else {
                throw LocalStorageProviderError.invalidRequest
            }
            let engine = try makeBackupEngine(
                keyReference: nil,
                remoteDestination:
                    try resolvedBackupRemoteDestination(
                        requested:
                            request.payload.remoteDestination,
                        backupID:
                            request.payload.backupID,
                        allowMissing:
                            replayingIntent
                    )
            )
            do {
                let existing = try engine.inspect(
                    backupID: request.payload.backupID
                )
                try validateBackupOwnership(
                    existing,
                    volumes: volumes,
                    projectUUID: context.projectUUID,
                    projectGeneration: context.projectGeneration
                )
                guard existing.manifestSHA256 ==
                        expectedManifest else {
                    throw LocalStorageProviderError
                        .dataProtectionConflict
                }
                try checkCancellation(
                    requestID: request.requestID
                )
                try engine.delete(
                    backupID: existing.backupID
                )
                return LocalStorageBackupResult(
                    disposition: .performed,
                    backupID: existing.backupID,
                    manifestSHA256:
                        existing.manifestSHA256,
                    verifiedVolumeIDs:
                        existing.volumes.map {
                            $0.source.volumeID
                        },
                    action: .delete,
                    deleted: true
                )
            } catch StorageBackupError.backupNotFound
                where replayingIntent {
                try engine.cleanupUnreferencedChunks()
                return LocalStorageBackupResult(
                    disposition: .alreadySatisfied,
                    backupID: request.payload.backupID,
                    manifestSHA256: expectedManifest,
                    verifiedVolumeIDs:
                        volumes.map(\.volumeID),
                    action: .delete,
                    deleted: true
                )
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        }
    }

    private func applyRestore(
        _ request:
            StorageProviderRequest<LocalStorageRestorePayload>,
        _ replayingIntent: Bool
    ) throws -> LocalStorageRestoreResult {
        _ = replayingIntent
        guard let context = request.mutationContext,
              LocalStorageFilesystemSession.validCanonicalUUID(
                  request.payload.sourceID
              ),
              !request.payload.targets.isEmpty,
              request.payload.targets.count <=
                LocalStorageProviderContract
                    .maximumDataProtectionVolumes,
              request.payload.targets ==
                request.payload.targets.sorted(by: {
                    if $0.sourceVolumeID !=
                        $1.sourceVolumeID {
                        return $0.sourceVolumeID <
                            $1.sourceVolumeID
                    }
                    return $0.targetVolumeID <
                        $1.targetVolumeID
                }),
              Set(
                  request.payload.targets.map(\.sourceVolumeID)
              ).count == request.payload.targets.count,
              Set(
                  request.payload.targets.map(\.targetVolumeID)
              ).count == request.payload.targets.count else {
            throw LocalStorageProviderError.invalidRequest
        }
        let targets = try request.payload.targets.map {
            try validatedRestoreTarget(
                $0,
                projectUUID: context.projectUUID,
                projectGeneration: context.projectGeneration
            )
        }
        guard targets.contains(where: {
            $0.targetVolumeID ==
                context.resourceUUID.uuidString.lowercased() &&
                $0.generation == context.resourceGeneration &&
                $0.fencingToken ==
                    context.fencingToken.uuidString.lowercased()
        }) else {
            throw LocalStorageProviderError.ownershipMismatch
        }

        switch request.payload.source {
        case .snapshot:
            guard request.payload.keyReference == nil,
                  request.payload.expectedManifestSHA256 == nil,
                  let referenceID =
                    request.payload.referenceID,
                  LocalStorageFilesystemSession
                    .validCanonicalUUID(referenceID),
                  targets.count == 1 else {
                throw LocalStorageProviderError.invalidRequest
            }
            let engine = try makeSnapshotEngine()
            let hooks = StorageSnapshotHooks(
                isCancelled: { [weak self] in
                    self?.cancellationRequested(
                        requestID: request.requestID
                    ) ?? true
                }
            )
            do {
                let snapshot = try engine.verify(
                    snapshotID: request.payload.sourceID,
                    hooks: hooks
                )
                guard snapshot.source.projectID ==
                        context.projectUUID
                            .uuidString.lowercased(),
                      snapshot.source.projectGeneration ==
                        context.projectGeneration,
                      snapshot.source.volumeID ==
                        targets[0].sourceVolumeID else {
                    throw LocalStorageProviderError
                        .ownershipMismatch
                }
                _ = try engine.restore(
                    snapshotID: snapshot.snapshotID,
                    toVolumeID: targets[0].targetVolumeID,
                    expectedGeneration: targets[0].generation,
                    expectedFencingToken:
                        targets[0].fencingToken,
                    referenceID: referenceID,
                    hooks: hooks
                )
                let verified = try engine.verify(
                    snapshotID: snapshot.snapshotID,
                    hooks: hooks
                )
                return LocalStorageRestoreResult(
                    disposition: .performed,
                    source: .snapshot,
                    sourceID: snapshot.snapshotID,
                    restoredTargetVolumeIDs: [
                        targets[0].targetVolumeID,
                    ],
                    verifiedContentSHA256: [
                        verified.snapshotContentTreeSHA256,
                    ]
                )
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        case .backup:
            guard request.payload.referenceID == nil,
                  let expectedManifestSHA256 =
                    request.payload.expectedManifestSHA256,
                  Self.validSHA256(
                      expectedManifestSHA256
                  ),
                  let keyReferenceText =
                    request.payload.keyReference else {
                throw LocalStorageProviderError.invalidRequest
            }
            let keyReference =
                try parseBackupKeyReference(keyReferenceText)
            let engine = try makeBackupEngine(
                keyReference: keyReference,
                remoteDestination:
                    try resolvedBackupRemoteDestination(
                        requested:
                            request.payload.remoteDestination,
                        backupID:
                            request.payload.sourceID
                    )
            )
            let hooks = StorageBackupHooks(
                isCancelled: { [weak self] in
                    self?.cancellationRequested(
                        requestID: request.requestID
                    ) ?? true
                }
            )
            do {
                let verified = try engine.verify(
                    backupID: request.payload.sourceID
                )
                guard verified.backup.manifestSHA256 ==
                        expectedManifestSHA256 else {
                    throw LocalStorageProviderError
                        .integrityMismatch
                }
                guard verified.backup.volumes.allSatisfy({
                    $0.source.projectID ==
                        context.projectUUID
                            .uuidString.lowercased() &&
                        $0.source.projectGeneration ==
                            context.projectGeneration
                }),
                Set(
                    verified.backup.volumes.map {
                        $0.source.volumeID
                    }
                ) == Set(targets.map(\.sourceVolumeID)) else {
                    throw LocalStorageProviderError
                        .ownershipMismatch
                }
                let restored = try engine.restore(
                    backupID: verified.backup.backupID,
                    targets: targets.map {
                        StorageBackupTargetRequest(
                            sourceVolumeID:
                                $0.sourceVolumeID,
                            targetVolumeID:
                                $0.targetVolumeID,
                            expectedGeneration:
                                $0.generation,
                            expectedFencingToken:
                                $0.fencingToken
                        )
                    },
                    hooks: hooks
                )
                return LocalStorageRestoreResult(
                    disposition: .performed,
                    source: .backup,
                    sourceID: restored.backup.backupID,
                    restoredTargetVolumeIDs:
                        restored.restoredTargetVolumeIDs,
                    verifiedContentSHA256:
                        restored.backup.volumes.map(
                            \.snapshotDigest
                        )
                )
            } catch {
                throw Self.normalizeDataProtection(error)
            }
        }
    }

    private func applyExpand(
        _ request: StorageProviderRequest<LocalStorageExpandPayload>,
        _ session: LocalStorageFilesystemSession
    ) throws -> LocalStorageMutationResult {
        guard let context = request.mutationContext,
              request.payload.capacityBytes > 0,
              request.payload.capacityBytes <= totalCapacityBytes else {
            throw LocalStorageProviderError.invalidRequest
        }
        let volumeID = context.resourceUUID.uuidString.lowercased()
        let metadata = try session.loadVolume(volumeID: volumeID)
        try validateProject(metadata, context: context)
        if request.payload.capacityBytes == metadata.capacityBytes,
           context.resourceGeneration == metadata.generation,
           context.fencingToken.uuidString.lowercased() ==
                metadata.fencingToken {
            return LocalStorageMutationResult(
                disposition: .alreadySatisfied,
                volume: try session.observe(metadata)
            )
        }
        guard request.payload.capacityBytes > metadata.capacityBytes,
              context.resourceGeneration == metadata.generation + 1 else {
            throw LocalStorageProviderError.generationMismatch
        }
        let delta = request.payload.capacityBytes - metadata.capacityBytes
        let scan = try session.scanVolumes()
        guard scan.ambiguousVolumeIDs.isEmpty else {
            throw LocalStorageProviderError.ambiguousVolume
        }
        let reserved = try reservedCapacity(scan)
        let filesystemAvailable = try session.filesystemAvailableBytes()
        guard delta <= totalCapacityBytes - reserved,
              delta <= filesystemAvailable else {
            throw LocalStorageProviderError.capacityExceeded
        }
        let updated = LocalStorageVolumeMetadata(
            volumeID: metadata.volumeID,
            name: metadata.name,
            projectID: metadata.projectID,
            projectGeneration: metadata.projectGeneration,
            generation: context.resourceGeneration,
            fencingToken: context.fencingToken.uuidString.lowercased(),
            capacityBytes: request.payload.capacityBytes,
            retention: metadata.retention,
            attachments: metadata.attachments
        )
        try session.writeVolume(updated)
        return LocalStorageMutationResult(
            disposition: .performed,
            volume: try session.observe(updated)
        )
    }

    private func applyDelete(
        _ request: StorageProviderRequest<LocalStorageDeletePayload>,
        _ session: LocalStorageFilesystemSession
    ) throws -> LocalStorageMutationResult {
        guard let context = request.mutationContext else {
            throw LocalStorageProviderError.invalidRequest
        }
        let volumeID = context.resourceUUID.uuidString.lowercased()
        let scan = try session.scanVolumes()
        if scan.ambiguousVolumeIDs.contains(volumeID) {
            throw LocalStorageProviderError.ambiguousVolume
        }
        guard let metadata = scan.volumes.first(where: {
            $0.0.volumeID == volumeID
        })?.0 else {
            return LocalStorageMutationResult(
                disposition: .alreadySatisfied,
                removedVolumeID: volumeID
            )
        }
        try validateOwnership(metadata, context: context)
        guard metadata.attachments.isEmpty else {
            throw LocalStorageProviderError.volumeAttached
        }
        try session.deleteVolume(metadata)
        return LocalStorageMutationResult(
            disposition: .performed,
            removedVolumeID: volumeID
        )
    }

    private func applyRecovery(
        _ request: StorageProviderRequest<LocalStorageRecoveryPayload>,
        _ replayingIntent: Bool
    ) throws -> LocalStorageRecoveryResult {
        _ = replayingIntent
        guard let recoveryContext = request.mutationContext,
              !request.payload.idempotencyKey.isEmpty else {
            throw LocalStorageProviderError.invalidRequest
        }
        let keySHA256 = Self.sha256(
            Data(request.payload.idempotencyKey.utf8)
        )
        let intent: LocalStorageMutationIntent
        do {
            let session = try makeSession()
            guard let pending = try session.loadIntent(
                keySHA256: keySHA256
            ) else {
                if let receipt = try session.loadReceipt(
                    keySHA256: keySHA256
                ) {
                    return LocalStorageRecoveryResult(
                        disposition: .alreadySatisfied,
                        recoveredOperation: receipt.operation,
                        recoveredRequestID: receipt.requestID
                    )
                }
                throw LocalStorageProviderError.recoveryNotFound
            }
            intent = pending
        }
        guard intent.operation != .recovery,
              intent.context.projectUUID ==
                recoveryContext.projectUUID,
              intent.context.projectGeneration ==
                recoveryContext.projectGeneration,
              intent.context.resourceUUID ==
                recoveryContext.resourceUUID,
              intent.context.resourceGeneration ==
                recoveryContext.resourceGeneration,
              intent.context.fencingToken ==
                recoveryContext.fencingToken else {
            throw LocalStorageProviderError.recoveryContextMismatch
        }
        try recover(intent: intent)
        return LocalStorageRecoveryResult(
            disposition: .recovered,
            recoveredOperation: intent.operation,
            recoveredRequestID: intent.requestID
        )
    }

    private func recover(
        intent: LocalStorageMutationIntent
    ) throws {
        let canonicalResult: Data
        switch intent.operation {
        case .create:
            let request = try StorageProviderCanonicalJSON.decodeRequest(
                LocalStorageCreatePayload.self,
                from: intent.canonicalRequest
            )
            let session = try makeSession()
            canonicalResult = try Self.encodeCanonical(
                applyCreate(request, session)
            )
        case .attach:
            let request = try StorageProviderCanonicalJSON.decodeRequest(
                LocalStorageAttachPayload.self,
                from: intent.canonicalRequest
            )
            let session = try makeSession()
            canonicalResult = try Self.encodeCanonical(
                applyAttach(request, session)
            )
        case .detach:
            let request = try StorageProviderCanonicalJSON.decodeRequest(
                LocalStorageDetachPayload.self,
                from: intent.canonicalRequest
            )
            let session = try makeSession()
            canonicalResult = try Self.encodeCanonical(
                applyDetach(request, session)
            )
        case .snapshot:
            let request = try StorageProviderCanonicalJSON
                .decodeRequest(
                    LocalStorageSnapshotPayload.self,
                    from: intent.canonicalRequest
            )
            canonicalResult = try Self.encodeCanonical(
                applySnapshot(request, true)
            )
        case .backup:
            let request = try StorageProviderCanonicalJSON
                .decodeRequest(
                    LocalStorageBackupPayload.self,
                    from: intent.canonicalRequest
            )
            canonicalResult = try Self.encodeCanonical(
                applyBackup(request, true)
            )
        case .restore:
            let request = try StorageProviderCanonicalJSON
                .decodeRequest(
                    LocalStorageRestorePayload.self,
                    from: intent.canonicalRequest
            )
            canonicalResult = try Self.encodeCanonical(
                applyRestore(request, true)
            )
        case .expand:
            let request = try StorageProviderCanonicalJSON.decodeRequest(
                LocalStorageExpandPayload.self,
                from: intent.canonicalRequest
            )
            let session = try makeSession()
            canonicalResult = try Self.encodeCanonical(
                applyExpand(request, session)
            )
        case .delete:
            let request = try StorageProviderCanonicalJSON.decodeRequest(
                LocalStorageDeletePayload.self,
                from: intent.canonicalRequest
            )
            let session = try makeSession()
            canonicalResult = try Self.encodeCanonical(
                applyDelete(request, session)
            )
        default:
            throw LocalStorageProviderError.recoveryContextMismatch
        }
        let session = try makeSession()
        try session.writeReceipt(
            LocalStorageMutationReceipt(
                idempotencyKeySHA256:
                    intent.idempotencyKeySHA256,
                requestSHA256: intent.requestSHA256,
                operation: intent.operation,
                requestID: UUID(uuidString: intent.requestID)!,
                canonicalResult: canonicalResult
            )
        )
        try session.removeIntent(
            keySHA256: intent.idempotencyKeySHA256
        )
    }

    private func ownedObservation(
        context: StorageProviderMutationContext
    ) throws -> LocalStorageVolumeObservation {
        let volume = try inspect(
            volumeID:
                context.resourceUUID.uuidString.lowercased()
        )
        guard volume.providerID ==
                LocalStorageProviderContract.providerID,
              volume.projectID ==
                context.projectUUID.uuidString.lowercased(),
              volume.projectGeneration ==
                context.projectGeneration else {
            throw LocalStorageProviderError.ownershipMismatch
        }
        guard volume.generation ==
                context.resourceGeneration else {
            throw LocalStorageProviderError.generationMismatch
        }
        guard volume.fencingToken ==
                context.fencingToken.uuidString.lowercased() else {
            throw LocalStorageProviderError.fencingConflict
        }
        return volume
    }

    private func validatedBackupVolume(
        _ payload: LocalStorageBackupVolumePayload,
        projectUUID: UUID,
        projectGeneration: Int
    ) throws -> LocalStorageBackupVolumePayload {
        guard LocalStorageFilesystemSession.validCanonicalUUID(
                payload.volumeID
              ),
              payload.generation > 0,
              LocalStorageFilesystemSession.validCanonicalUUID(
                  payload.fencingToken
              ) else {
            throw LocalStorageProviderError.invalidRequest
        }
        let volume = try inspect(volumeID: payload.volumeID)
        guard volume.providerID ==
                LocalStorageProviderContract.providerID,
              volume.projectID ==
                projectUUID.uuidString.lowercased(),
              volume.projectGeneration == projectGeneration else {
            throw LocalStorageProviderError.ownershipMismatch
        }
        guard volume.generation == payload.generation else {
            throw LocalStorageProviderError.generationMismatch
        }
        guard volume.fencingToken == payload.fencingToken else {
            throw LocalStorageProviderError.fencingConflict
        }
        return payload
    }

    private func validatedRestoreTarget(
        _ payload: LocalStorageRestoreTargetPayload,
        projectUUID: UUID,
        projectGeneration: Int
    ) throws -> LocalStorageRestoreTargetPayload {
        guard LocalStorageFilesystemSession.validCanonicalUUID(
                payload.sourceVolumeID
              ),
              LocalStorageFilesystemSession.validCanonicalUUID(
                  payload.targetVolumeID
              ),
              payload.generation > 0,
              LocalStorageFilesystemSession.validCanonicalUUID(
                  payload.fencingToken
              ) else {
            throw LocalStorageProviderError.invalidRequest
        }
        let volume = try inspect(
            volumeID: payload.targetVolumeID
        )
        guard volume.providerID ==
                LocalStorageProviderContract.providerID,
              volume.projectID ==
                projectUUID.uuidString.lowercased(),
              volume.projectGeneration == projectGeneration else {
            throw LocalStorageProviderError.ownershipMismatch
        }
        guard volume.generation == payload.generation else {
            throw LocalStorageProviderError.generationMismatch
        }
        guard volume.fencingToken == payload.fencingToken else {
            throw LocalStorageProviderError.fencingConflict
        }
        return payload
    }

    private func parseBackupKeyReference(
        _ value: String
    ) throws -> HostwrightSecretReference {
        do {
            let reference =
                try HostwrightSecretReference.parse(value)
            guard reference.providerKind == .keychain else {
                throw LocalStorageProviderError
                    .backupKeyRejected
            }
            return reference
        } catch let error as LocalStorageProviderError {
            throw error
        } catch {
            throw LocalStorageProviderError.backupKeyRejected
        }
    }

    private func makeSnapshotEngine()
        throws -> StorageSnapshotEngine
    {
        try StorageSnapshotEngine(
            provider: self,
            snapshotRootURL: rootURL.appendingPathComponent(
                "snapshots",
                isDirectory: true
            )
        )
    }

    private func makeBackupEngine(
        keyReference: HostwrightSecretReference?,
        remoteDestination:
            StorageBackupRemoteDestination? = nil
    ) throws -> StorageBackupEngine {
        let resolvedReference: HostwrightSecretReference
        if let keyReference {
            resolvedReference = keyReference
        } else {
            resolvedReference = try HostwrightSecretReference(
                service: "hostwright-storage",
                account: "metadata-only"
            )
        }
        let remoteTransport:
            (any StorageBackupRemoteTransport)?
        if let remoteDestination {
            _ = try remoteDestination
                .validatedCredentialReferences()
            do {
                remoteTransport = try
                    backupRemoteTransportFactory
                    .makeTransport(
                        destination: remoteDestination,
                        secretStore:
                            backupRemoteSecretStore
                    )
            } catch let error as StorageBackupError {
                throw error
            } catch {
                throw StorageBackupError
                    .remoteCredentialFailure
            }
        } else {
            remoteTransport = nil
        }
        return try StorageBackupEngine(
            provider: self,
            snapshotEngine: makeSnapshotEngine(),
            backupRootURL: rootURL.appendingPathComponent(
                "backups",
                isDirectory: true
            ),
            keyResolver: backupKeyResolver,
            keyReference: resolvedReference,
            remoteDestination: remoteDestination,
            remoteTransport: remoteTransport
        )
    }

    private func resolvedBackupRemoteDestination(
        requested:
            StorageBackupRemoteDestination?,
        backupID: String,
        allowMissing: Bool = false
    ) throws -> StorageBackupRemoteDestination? {
        if let requested {
            _ = try requested
                .validatedCredentialReferences()
            return requested
        }
        do {
            return try makeBackupEngine(
                keyReference: nil
            ).inspect(
                backupID: backupID
            ).remoteDestination
        } catch StorageBackupError.backupNotFound
            where allowMissing {
            return nil
        }
    }

    private func snapshotSourceMatches(
        _ source: StorageSnapshotVolumeIdentity,
        volume: LocalStorageVolumeObservation
    ) -> Bool {
        source.volumeID == volume.volumeID &&
            source.providerID == volume.providerID &&
            source.projectID == volume.projectID &&
            source.projectGeneration ==
                volume.projectGeneration &&
            source.generation == volume.generation &&
            source.fencingToken == volume.fencingToken &&
            source.dataDevice == volume.dataDevice &&
            source.dataInode == volume.dataInode
    }

    private func snapshotResult(
        _ snapshot: StorageSnapshotRecord,
        disposition: LocalStorageMutationDisposition,
        action: LocalStorageSnapshotAction? = nil,
        retainedBy: [String]? = nil,
        exportedPath: String? = nil,
        deleted: Bool? = nil
    ) -> LocalStorageSnapshotResult {
        LocalStorageSnapshotResult(
            disposition: disposition,
            snapshotID: snapshot.snapshotID,
            sourceVolumeID: snapshot.source.volumeID,
            sourceGeneration: snapshot.source.generation,
            sourceFencingToken:
                snapshot.source.fencingToken,
            consistencyClass: snapshot.consistencyClass,
            parentContentTreeSHA256:
                snapshot.parentContentTreeSHA256,
            contentTreeSHA256:
                snapshot.snapshotContentTreeSHA256,
            lineage: snapshot.lineage,
            action: action,
            retainedBy: retainedBy,
            exportedPath: exportedPath,
            deleted: deleted
        )
    }

    private func validateSnapshotOwnership(
        _ snapshot: StorageSnapshotRecord,
        volume: LocalStorageVolumeObservation
    ) throws {
        guard snapshotSourceMatches(
            snapshot.source,
            volume: volume
        ) else {
            throw LocalStorageProviderError.ownershipMismatch
        }
    }

    private func verifySnapshotExport(
        _ snapshot: StorageSnapshotRecord,
        at destination: URL,
        hooks: StorageSnapshotHooks
    ) throws {
        try StorageSnapshotFilesystem.ensureSafeParent(
            destination.deletingLastPathComponent()
        )
        try StorageSnapshotFilesystem.requireDirectory(
            destination
        )
        let exported: StorageSnapshotRecord =
            try readBoundedSnapshotRecord(
                destination.appendingPathComponent(
                    "metadata.json",
                    isDirectory: false
                )
            )
        guard exported == snapshot else {
            throw LocalStorageProviderError
                .dataProtectionConflict
        }
        let digest = try StorageSnapshotFilesystem.hashTree(
            at: destination.appendingPathComponent(
                "data",
                isDirectory: true
            ),
            hooks: hooks
        )
        guard digest.sha256 ==
                snapshot.snapshotContentTreeSHA256 else {
            throw LocalStorageProviderError.integrityMismatch
        }
    }

    private func readBoundedSnapshotRecord(
        _ url: URL
    ) throws -> StorageSnapshotRecord {
        let descriptor = open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw LocalStorageProviderError.unsafePath
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_size > 0,
              metadata.st_size <=
                LocalStorageProviderContract.maximumMetadataBytes else {
            throw LocalStorageProviderError.unsafePath
        }
        var data = Data(count: Int(metadata.st_size))
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let count = data.withUnsafeMutableBytes {
                Darwin.read(
                    descriptor,
                    $0.baseAddress!.advanced(by: offset),
                    remaining
                )
            }
            guard count > 0 else {
                throw LocalStorageProviderError.ioFailure
            }
            offset += count
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(
                StorageSnapshotRecord.self,
                from: data
            )
        } catch {
            throw LocalStorageProviderError
                .dataProtectionConflict
        }
    }

    private func validateBackupRecord(
        _ backup: StorageBackupRecord,
        name: String,
        keyReference: HostwrightSecretReference,
        volumes: [LocalStorageBackupVolumePayload],
        remoteDestination:
            StorageBackupRemoteDestination?,
        projectUUID: UUID,
        projectGeneration: Int
    ) throws {
        guard backup.name == name,
              backup.keyReferenceRedacted ==
                keyReference.redactedDescription,
              backup.remoteDestination ==
                remoteDestination,
              backup.volumes.count == volumes.count else {
            throw LocalStorageProviderError
                .dataProtectionConflict
        }
        try validateBackupOwnership(
            backup,
            volumes: volumes,
            projectUUID: projectUUID,
            projectGeneration: projectGeneration
        )
    }

    private func validateBackupOwnership(
        _ backup: StorageBackupRecord,
        volumes: [LocalStorageBackupVolumePayload],
        projectUUID: UUID,
        projectGeneration: Int
    ) throws {
        guard backup.volumes.count == volumes.count else {
            throw LocalStorageProviderError
                .dataProtectionConflict
        }
        let expected = Dictionary(
            uniqueKeysWithValues: volumes.map {
                ($0.volumeID, $0)
            }
        )
        guard backup.volumes.allSatisfy({
            guard let volume = expected[
                $0.source.volumeID
            ] else {
                return false
            }
            return $0.source.providerID ==
                    LocalStorageProviderContract.providerID &&
                $0.source.projectID ==
                    projectUUID.uuidString.lowercased() &&
                $0.source.projectGeneration ==
                    projectGeneration &&
                $0.source.generation == volume.generation &&
                $0.source.fencingToken ==
                    volume.fencingToken
        }) else {
            throw LocalStorageProviderError
                .dataProtectionConflict
        }
    }

    private func validateBackupContainsOwnership(
        _ backup: StorageBackupRecord,
        volumes: [LocalStorageBackupVolumePayload],
        projectUUID: UUID,
        projectGeneration: Int
    ) throws {
        let required = Dictionary(
            uniqueKeysWithValues: volumes.map {
                ($0.volumeID, $0)
            }
        )
        let backedUp = Dictionary(
            uniqueKeysWithValues: backup.volumes.map {
                ($0.source.volumeID, $0)
            }
        )
        guard required.allSatisfy({
            guard let volume = backedUp[$0.key] else {
                return false
            }
            return volume.source.providerID ==
                    LocalStorageProviderContract.providerID &&
                volume.source.projectID ==
                    projectUUID.uuidString.lowercased() &&
                volume.source.projectGeneration ==
                    projectGeneration &&
                volume.source.generation ==
                    $0.value.generation &&
                volume.source.fencingToken ==
                    $0.value.fencingToken
        }) else {
            throw LocalStorageProviderError
                .dataProtectionConflict
        }
    }

    private func validateExpectedManifest(
        _ expected: String?,
        backup: StorageBackupRecord
    ) throws {
        guard let expected else {
            return
        }
        guard Self.validSHA256(expected),
              backup.manifestSHA256 == expected else {
            throw LocalStorageProviderError
                .dataProtectionConflict
        }
    }

    private func backupResult(
        _ verified: StorageBackupVerifyResult,
        disposition: LocalStorageMutationDisposition,
        action: LocalStorageBackupAction? = nil
    ) -> LocalStorageBackupResult {
        LocalStorageBackupResult(
            disposition: disposition,
            backupID: verified.backup.backupID,
            manifestSHA256:
                verified.backup.manifestSHA256,
            verifiedVolumeIDs:
                verified.verifiedVolumeIDs,
            action: action
        )
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 &&
            value.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
    }

    private static func normalizeDataProtection(
        _ error: Error
    ) -> LocalStorageProviderError {
        if let local = error as? LocalStorageProviderError {
            return local
        }
        if let snapshot = error as? StorageSnapshotError {
            return switch snapshot {
            case .snapshotNotFound:
                .dataProtectionNotFound
            case .snapshotAlreadyExists,
                 .snapshotRetained,
                 .snapshotReferenced:
                .dataProtectionConflict
            case .invalidSnapshotID,
                 .applicationConsistencyRequiresHooks:
                .invalidRequest
            case .staleGeneration:
                .generationMismatch
            case .fencingConflict:
                .fencingConflict
            case .cancelled:
                .cancelled
            case .unsafePath,
                 .destinationExists,
                 .wrongParent:
                .unsafePath
            case .integrityMismatch:
                .integrityMismatch
            case .ioFailure:
                .ioFailure
            }
        }
        if let backup = error as? StorageBackupError {
            return switch backup {
            case .backupNotFound:
                .dataProtectionNotFound
            case .backupAlreadyExists, .retained:
                .dataProtectionConflict
            case .invalidBackupID,
                 .incompleteBackup,
                 .targetValidationFailed,
                 .invalidRemoteDestination:
                .invalidRequest
            case .wrongKey:
                .backupKeyRejected
            case .integrityMismatch:
                .integrityMismatch
            case .cancelled:
                .cancelled
            case .wrongParent, .unmanagedTarget:
                .unsafePath
            case .ioFailure,
                 .diskFull,
                 .restoreRollbackFailure,
                 .remoteCredentialFailure,
                 .remoteObjectNotFound,
                 .remoteTransportFailure:
                .ioFailure
            }
        }
        return .ioFailure
    }

    private func observation(
        session: LocalStorageFilesystemSession,
        volumeID: String?
    ) throws -> LocalStorageObservation {
        let scan = try session.scanVolumes()
        let selected: [(
            LocalStorageVolumeMetadata,
            LocalStorageVolumeObservation
        )]
        if let volumeID {
            guard let exact = scan.volumes.first(where: {
                $0.0.volumeID == volumeID
            }) else {
                if scan.ambiguousVolumeIDs.contains(volumeID) {
                    throw LocalStorageProviderError.ambiguousVolume
                }
                throw LocalStorageProviderError.volumeNotFound
            }
            selected = [exact]
        } else {
            selected = scan.volumes
        }
        return LocalStorageObservation(
            volumes: selected.map(\.1),
            unmanagedEntries: scan.unmanagedEntries,
            ambiguousVolumeIDs: scan.ambiguousVolumeIDs,
            pendingRecoveryIDs: try session.pendingRecoveryIDs(),
            totalCapacityBytes: totalCapacityBytes,
            reservedCapacityBytes: try reservedCapacity(scan)
        )
    }

    private func ownedVolume(
        context: StorageProviderMutationContext,
        session: LocalStorageFilesystemSession
    ) throws -> LocalStorageVolumeMetadata {
        let metadata = try session.loadVolume(
            volumeID: context.resourceUUID.uuidString.lowercased()
        )
        try validateOwnership(metadata, context: context)
        return metadata
    }

    private func attachmentOwnedVolume(
        context: StorageProviderMutationContext,
        volumeGeneration: Int,
        volumeFencingToken: String,
        session: LocalStorageFilesystemSession
    ) throws -> LocalStorageVolumeMetadata {
        let metadata = try session.loadVolume(
            volumeID: context.resourceUUID.uuidString.lowercased()
        )
        try validateProject(metadata, context: context)
        guard metadata.generation == volumeGeneration else {
            throw LocalStorageProviderError.generationMismatch
        }
        guard metadata.fencingToken == volumeFencingToken else {
            throw LocalStorageProviderError.fencingConflict
        }
        return metadata
    }

    private func validateOwnership(
        _ metadata: LocalStorageVolumeMetadata,
        context: StorageProviderMutationContext
    ) throws {
        try validateProject(metadata, context: context)
        guard metadata.generation == context.resourceGeneration else {
            throw LocalStorageProviderError.generationMismatch
        }
        guard metadata.fencingToken ==
                context.fencingToken.uuidString.lowercased() else {
            throw LocalStorageProviderError.fencingConflict
        }
    }

    private func validateProject(
        _ metadata: LocalStorageVolumeMetadata,
        context: StorageProviderMutationContext
    ) throws {
        guard metadata.providerID ==
                LocalStorageProviderContract.providerID,
              metadata.volumeID ==
                context.resourceUUID.uuidString.lowercased(),
              metadata.projectID ==
                context.projectUUID.uuidString.lowercased(),
              metadata.projectGeneration ==
                context.projectGeneration else {
            throw LocalStorageProviderError.ownershipMismatch
        }
    }

    private func replacing(
        _ metadata: LocalStorageVolumeMetadata,
        attachments: [LocalStorageAttachmentMetadata]
    ) -> LocalStorageVolumeMetadata {
        LocalStorageVolumeMetadata(
            volumeID: metadata.volumeID,
            name: metadata.name,
            projectID: metadata.projectID,
            projectGeneration: metadata.projectGeneration,
            generation: metadata.generation,
            fencingToken: metadata.fencingToken,
            capacityBytes: metadata.capacityBytes,
            retention: metadata.retention,
            attachments: attachments
        )
    }

    private func reservedCapacity(
        _ scan: LocalStorageVolumeScan
    ) throws -> Int64 {
        try scan.volumes.reduce(Int64(0)) { partial, volume in
            let (sum, overflow) = partial.addingReportingOverflow(
                volume.0.capacityBytes
            )
            guard !overflow, sum <= totalCapacityBytes else {
                throw LocalStorageProviderError.capacityExceeded
            }
            return sum
        }
    }

    private func makeSession() throws -> LocalStorageFilesystemSession {
        try LocalStorageFilesystemSession(
            rootURL: rootURL,
            totalCapacityBytes: totalCapacityBytes
        )
    }

    private func validate<Payload>(
        _ request: StorageProviderRequest<Payload>
    ) throws {
        let cancelled = cancellationRequested(requestID: request.requestID)
        validationLock.lock()
        defer { validationLock.unlock() }
        try requestValidator.validate(
            request,
            nowUnixMilliseconds:
                Int64(Date().timeIntervalSince1970 * 1_000),
            cancellationRequested: cancelled
        )
    }

    private func checkCancellation(requestID: UUID) throws {
        guard !Task<Never, Never>.isCancelled,
              !cancellationRequested(requestID: requestID) else {
            throw LocalStorageProviderError.cancelled
        }
    }

    private func cancellationRequested(requestID: UUID) -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelledRequestIDs.contains(requestID)
    }

    private func clearCancellation(requestID: UUID) {
        cancellationLock.lock()
        cancelledRequestIDs.remove(requestID)
        cancellationLock.unlock()
    }

    private static func stableRequestSHA256(_ request: Data) throws -> String {
        guard var object = try JSONSerialization.jsonObject(
            with: request
        ) as? [String: Any] else {
            throw LocalStorageProviderError.invalidRequest
        }
        object.removeValue(forKey: "requestID")
        object.removeValue(forKey: "deadline")
        let stable = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return sha256(stable)
    }

    private static func encodeCanonical<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decodeCanonical<Value: Codable>(
        _ type: Value.Type,
        data: Data
    ) throws -> Value {
        let value = try JSONDecoder().decode(type, from: data)
        guard try encodeCanonical(value) == data else {
            throw LocalStorageProviderError.ambiguousVolume
        }
        return value
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func decodeRoute(_ data: Data) throws -> (
        requestID: UUID,
        operation: StorageProviderOperation
    ) {
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let requestIDText = object["requestID"] as? String,
              let requestID = UUID(uuidString: requestIDText),
              requestID.uuidString.lowercased() == requestIDText,
              let operationText = object["operation"] as? String,
              let operation = StorageProviderOperation(
                  rawValue: operationText
              ) else {
            throw LocalStorageProviderError.invalidRequest
        }
        return (requestID, operation)
    }

    private static func requiresRecovery(_ error: Error) -> Bool {
        guard let error = error as? LocalStorageProviderError else {
            return true
        }
        return switch error {
        case .ioFailure,
             .ambiguousVolume,
             .unsafePath,
             .unsafeOwnership,
             .unsafePermissions,
             .crossDeviceEntry,
             .integrityMismatch,
             .cancelled,
             .recoveryContextMismatch:
            true
        default:
            false
        }
    }

    private static func failure(for error: Error) -> StorageProviderFailure {
        if let error = error as? StorageProviderProtocolError {
            return StorageProviderFailureNormalizer.normalize(error)
        }
        if error is DecodingError {
            return StorageProviderFailure(
                category: .invalidRequest,
                retryDisposition: .never,
                recoveryDisposition: .none,
                diagnostic:
                    "The storage provider payload does not match the selected operation.",
                guidance:
                    "Send the bounded typed payload for the negotiated operation."
            )
        }
        guard let error = error as? LocalStorageProviderError else {
            return StorageProviderFailure(
                category: .internalFailure,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve,
                diagnostic: "The local storage provider failed before returning verified evidence.",
                guidance: "Re-observe exact owned storage before retrying."
            )
        }
        switch error {
        case .cancelled:
            return StorageProviderFailureNormalizer.normalize(
                .cancelled,
                operation: .recovery
            )
        case .unavailable:
            return StorageProviderFailure(
                category: .unavailable,
                retryDisposition: .never,
                recoveryDisposition: .none,
                diagnostic: "The built-in local provider does not implement this operation.",
                guidance: "Select a provider that advertises the required capability."
            )
        case .generationMismatch:
            return StorageProviderFailure(
                category: .staleGeneration,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve,
                diagnostic: "The requested storage generation is stale.",
                guidance: "Re-observe the exact volume generation before retrying."
            )
        case .fencingConflict:
            return StorageProviderFailure(
                category: .fencingConflict,
                retryDisposition: .never,
                recoveryDisposition: .safeHold,
                diagnostic: "The storage fencing token does not match current ownership.",
                guidance: "Stop mutation and recover from authoritative ownership state."
            )
        case .idempotencyConflict, .journalLimitExceeded:
            return StorageProviderFailure(
                category: .replayedRequest,
                retryDisposition: .never,
                recoveryDisposition: .safeHold,
                diagnostic: "The storage idempotency journal rejected the request.",
                guidance: "Resolve the durable journal record before retrying."
            )
        case .integrityMismatch:
            return StorageProviderFailure(
                category: .rejected,
                retryDisposition: .never,
                recoveryDisposition: .safeHold,
                diagnostic:
                    "Storage data-protection integrity verification failed.",
                guidance:
                    "Preserve the source and recovery record; do not restore or delete unverified data."
            )
        case .backupKeyRejected:
            return StorageProviderFailure(
                category: .permissionDenied,
                retryDisposition: .never,
                recoveryDisposition: .none,
                diagnostic:
                    "The configured backup key reference could not verify this backup.",
                guidance:
                    "Use the exact Hostwright-managed Keychain reference for this backup."
            )
        case .unsafePath,
             .unsafeOwnership,
             .unsafePermissions,
             .crossDeviceEntry:
            return StorageProviderFailure(
                category: .permissionDenied,
                retryDisposition: .never,
                recoveryDisposition: .safeHold,
                diagnostic: "The local provider rejected an unsafe filesystem boundary.",
                guidance: "Restore private owned storage paths without weakening validation."
            )
        case .ambiguousVolume,
             .ownershipMismatch,
             .recoveryContextMismatch,
             .dataProtectionConflict:
            return StorageProviderFailure(
                category: .ambiguousEffect,
                retryDisposition: .resumeFromCheckpoint,
                recoveryDisposition: .safeHold,
                diagnostic: "Exact storage ownership or recovery state is ambiguous.",
                guidance: "Do not mutate or delete data until exact ownership is restored."
            )
        case .dataProtectionNotFound:
            return StorageProviderFailure(
                category: .rejected,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve,
                diagnostic:
                    "The requested snapshot or backup does not exist.",
                guidance:
                    "Re-observe data-protection inventory before retrying."
            )
        case .ioFailure:
            return StorageProviderFailure(
                category: .internalFailure,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve,
                diagnostic: "The local filesystem operation did not complete durably.",
                guidance: "Re-observe the exact volume and pending recovery record."
            )
        default:
            return StorageProviderFailure(
                category: .rejected,
                retryDisposition: .never,
                recoveryDisposition: .none,
                diagnostic: "The local storage provider rejected the request.",
                guidance: "Correct the request or satisfy its explicit precondition."
            )
        }
    }
}
