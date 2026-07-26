import CryptoKit
import Foundation

public struct StorageAttachmentCoordinator: Sendable {
    public static let forceDetachAuthorizationPrefix =
        "hostwright-force-detach:"

    public let nowUnixMilliseconds: Int64

    public init(
        nowUnixMilliseconds: Int64 = Int64(
            Date().timeIntervalSince1970 * 1_000
        )
    ) {
        self.nowUnixMilliseconds = nowUnixMilliseconds
    }

    public func beginAttach(
        _ intent: StorageAttachmentIntent,
        in ledger: StorageAttachmentLedger
    ) throws -> StorageAttachmentTransition {
        try validate(intent)
        if let existing = ledger.record(id: intent.attachmentID) {
            if isAttachReplay(intent, existing: existing) {
                return transition(
                    .alreadySatisfied,
                    record: existing,
                    ledger: ledger
                )
            }
            guard existing.checkpoint == .detachedCommitted,
                  let expected = intent.expectedAuthority else {
                throw failure(
                    .holderConflict,
                    .safeAfterObservation,
                    "The attachment identity is already owned by another active intent."
                )
            }
            try requireAuthority(expected, record: existing)
            try requireSuccessor(
                intent.authority,
                after: existing.authority
            )
        } else {
            guard intent.expectedAuthority == nil,
                  intent.authority.generation == 1 else {
                throw failure(
                    .staleGeneration,
                    .safeAfterObservation,
                    "A new attachment must begin at generation 1 without replacement authority."
                )
            }
        }

        let active = ledger.records.filter {
            $0.checkpoint != .detachedCommitted &&
                $0.id != intent.attachmentID
        }
        guard !active.contains(where: {
            $0.volumeID == intent.volumeID &&
                (!$0.readOnly || !intent.readOnly)
        }) else {
            throw failure(
                .singleWriterConflict,
                .safeAfterObservation,
                "A volume cannot have a second active writer or mix readers with a writer."
            )
        }
        guard !active.contains(where: {
            $0.volumeID == intent.volumeID &&
                $0.nodeUUID == intent.nodeUUID &&
                $0.workloadUUID == intent.workloadUUID
        }) else {
            throw failure(
                .holderConflict,
                .safeAfterObservation,
                "The node and workload already hold an active attachment for this volume."
            )
        }

        let expiry = try leaseExpiry(
            durationMilliseconds: intent.leaseDurationMilliseconds
        )
        let record = try StorageAttachmentRecord(
            id: intent.attachmentID,
            volumeID: intent.volumeID,
            nodeUUID: intent.nodeUUID,
            workloadUUID: intent.workloadUUID,
            accessMode: intent.accessMode,
            readOnly: intent.readOnly,
            authority: intent.authority,
            operationID: intent.operationID,
            idempotencyKey: intent.idempotencyKey,
            checkpoint: .attachIntentPersisted,
            leaseRenewedAtUnixMilliseconds: nowUnixMilliseconds,
            leaseExpiresAtUnixMilliseconds: expiry
        )
        return try replacing(record, in: ledger, disposition: .performed)
    }

    public func advance(
        attachmentID: String,
        expectedAuthority: StorageAttachmentAuthority,
        to target: StorageAttachmentCheckpoint,
        providerObservationSHA256: String? = nil,
        interruption: StorageAttachmentInterruption = .none,
        in ledger: StorageAttachmentLedger
    ) throws -> StorageAttachmentTransition {
        let record = try requireRecord(attachmentID, in: ledger)
        try requireAuthority(expectedAuthority, record: record)
        guard record.leaseStatus(
            atUnixMilliseconds: nowUnixMilliseconds
        ) == .active else {
            throw failure(
                record.ambiguousHoldReason == nil
                    ? .leaseExpired
                    : .ambiguousHold,
                .resumeFromCheckpoint,
                record.ambiguousHoldReason == nil
                    ? "The attachment lease is stale; acquire a new fence before mutation."
                    : "The attachment is held pending explicit provider observation."
            )
        }
        guard record.ambiguousHoldReason == nil else {
            throw failure(
                .ambiguousHold,
                .resumeFromCheckpoint,
                "The attachment is held pending explicit provider observation."
            )
        }
        if record.checkpoint == target {
            if let providerObservationSHA256,
               record.providerObservationSHA256 !=
                providerObservationSHA256 {
                throw failure(
                    .invalidTransition,
                    .safeAfterObservation,
                    "A replay supplied different provider observation evidence."
                )
            }
            return transition(
                .alreadySatisfied,
                record: record,
                ledger: ledger
            )
        }
        guard record.checkpoint.next == target else {
            throw failure(
                .invalidTransition,
                .never,
                "Attachment checkpoints must advance exactly one durable step."
            )
        }

        if interruption != .none {
            if record.checkpoint.providerEffectMayBeAmbiguous {
                let held = try copy(
                    record,
                    ambiguousHoldReason:
                        "provider effect \(interruption.rawValue); exact observation required"
                )
                return try replacing(
                    held,
                    in: ledger,
                    disposition: .held
                )
            }
            return transition(
                .interrupted,
                record: record,
                ledger: ledger
            )
        }

        var observation = record.providerObservationSHA256
        if target == .attachProviderObserved ||
            target == .detachProviderAbsentObserved {
            guard let providerObservationSHA256,
                  StorageAttachmentValidation.validSHA256(
                      providerObservationSHA256
                  ) else {
                throw failure(
                    .invalidArgument,
                    .never,
                    "Provider observation checkpoints require lowercase SHA256 evidence."
                )
            }
            observation = providerObservationSHA256
        } else if providerObservationSHA256 != nil {
            throw failure(
                .invalidTransition,
                .never,
                "Provider observation evidence is accepted only at observation checkpoints."
            )
        }
        if target == .attachedCommitted ||
            target == .detachedCommitted {
            guard observation != nil else {
                throw failure(
                    .invalidTransition,
                    .safeAfterObservation,
                    "Commit requires prior provider observation evidence."
                )
            }
        }

        let advanced = try copy(
            record,
            checkpoint: target,
            providerObservationSHA256: observation
        )
        return try replacing(
            advanced,
            in: ledger,
            disposition: .performed
        )
    }

    public func renewLease(
        attachmentID: String,
        holderNodeUUID: String,
        holderWorkloadUUID: String,
        expectedAuthority: StorageAttachmentAuthority,
        durationMilliseconds: Int64,
        in ledger: StorageAttachmentLedger
    ) throws -> StorageAttachmentTransition {
        let record = try requireRecord(attachmentID, in: ledger)
        try requireAuthority(expectedAuthority, record: record)
        try requireHolder(
            nodeUUID: holderNodeUUID,
            workloadUUID: holderWorkloadUUID,
            record: record
        )
        guard record.leaseStatus(
            atUnixMilliseconds: nowUnixMilliseconds
        ) == .active else {
            throw failure(
                record.ambiguousHoldReason == nil
                    ? .leaseExpired
                    : .ambiguousHold,
                .resumeFromCheckpoint,
                "Only the exact active holder may renew an attachment lease."
            )
        }
        let expiry = try leaseExpiry(
            durationMilliseconds: durationMilliseconds
        )
        guard expiry >= record.leaseExpiresAtUnixMilliseconds else {
            throw failure(
                .invalidArgument,
                .never,
                "Lease renewal cannot shorten the authoritative expiry."
            )
        }
        if record.leaseRenewedAtUnixMilliseconds ==
            nowUnixMilliseconds,
           record.leaseExpiresAtUnixMilliseconds == expiry {
            return transition(
                .alreadySatisfied,
                record: record,
                ledger: ledger
            )
        }
        let renewed = try copy(
            record,
            leaseRenewedAtUnixMilliseconds: nowUnixMilliseconds,
            leaseExpiresAtUnixMilliseconds: expiry
        )
        return try replacing(
            renewed,
            in: ledger,
            disposition: .performed
        )
    }

    public func beginDetach(
        _ intent: StorageDetachIntent,
        in ledger: StorageAttachmentLedger
    ) throws -> StorageAttachmentTransition {
        let record = try requireRecord(intent.attachmentID, in: ledger)
        if record.checkpoint == .detachedCommitted {
            return transition(
                .alreadySatisfied,
                record: record,
                ledger: ledger
            )
        }
        if isDetachReplay(intent, existing: record) {
            return transition(
                .alreadySatisfied,
                record: record,
                ledger: ledger
            )
        }
        try validate(intent)
        try requireAuthority(intent.expectedAuthority, record: record)
        try requireSuccessor(
            intent.replacementAuthority,
            after: record.authority
        )
        try requireHolder(
            nodeUUID: intent.holderNodeUUID,
            workloadUUID: intent.holderWorkloadUUID,
            record: record
        )

        let isForced = intent.forceAuthorization != nil ||
            intent.forceAuthorizationExpiresAtUnixMilliseconds != nil
        var forceAuthorizationSHA256: String?
        if isForced {
            guard let authorization = intent.forceAuthorization,
                  let expiresAt =
                    intent.forceAuthorizationExpiresAtUnixMilliseconds
            else {
                throw failure(
                    .authorizationRequired,
                    .never,
                    "Force detach requires the token and its bound expiry."
                )
            }
            let authorizationLifetime =
                expiresAt.subtractingReportingOverflow(
                    nowUnixMilliseconds
                )
            guard !authorizationLifetime.overflow,
                  authorizationLifetime.partialValue > 0,
                  authorizationLifetime.partialValue <=
                    StorageAttachmentValidation
                        .maximumLeaseMilliseconds else {
                throw failure(
                    .authorizationExpired,
                    .never,
                    "Force-detach authorization is expired or exceeds the bounded authorization window."
                )
            }
            let expected = forceDetachAuthorization(
                for: record,
                validUntilUnixMilliseconds: expiresAt
            )
            guard authorization == expected else {
                throw failure(
                    .authorizationMismatch,
                    .never,
                    "Force-detach authorization does not match the exact holder and fence."
                )
            }
            forceAuthorizationSHA256 = Self.sha256(authorization)
        } else {
            guard record.leaseStatus(
                atUnixMilliseconds: nowUnixMilliseconds
            ) == .active else {
                throw failure(
                    record.ambiguousHoldReason == nil
                        ? .authorizationRequired
                        : .ambiguousHold,
                    .resumeFromCheckpoint,
                    "A stale or ambiguous holder requires an exact force-detach authorization."
                )
            }
        }

        let expiry = try leaseExpiry(
            durationMilliseconds: intent.leaseDurationMilliseconds
        )
        let detaching = try StorageAttachmentRecord(
            id: record.id,
            volumeID: record.volumeID,
            nodeUUID: record.nodeUUID,
            workloadUUID: record.workloadUUID,
            accessMode: record.accessMode,
            readOnly: record.readOnly,
            authority: intent.replacementAuthority,
            operationID: intent.operationID,
            idempotencyKey: intent.idempotencyKey,
            checkpoint: .detachIntentPersisted,
            leaseRenewedAtUnixMilliseconds: nowUnixMilliseconds,
            leaseExpiresAtUnixMilliseconds: expiry,
            forceDetachAuthorizationSHA256:
                forceAuthorizationSHA256
        )
        return try replacing(
            detaching,
            in: ledger,
            disposition: .performed
        )
    }

    public func resolveAmbiguous(
        attachmentID: String,
        expectedAuthority: StorageAttachmentAuthority,
        providerObservedAttached: Bool,
        providerObservationSHA256: String,
        in ledger: StorageAttachmentLedger
    ) throws -> StorageAttachmentTransition {
        let record = try requireRecord(attachmentID, in: ledger)
        try requireAuthority(expectedAuthority, record: record)
        guard record.ambiguousHoldReason != nil,
              record.checkpoint.providerEffectMayBeAmbiguous,
              StorageAttachmentValidation.validSHA256(
                  providerObservationSHA256
              ) else {
            throw failure(
                .invalidTransition,
                .safeAfterObservation,
                "Ambiguous recovery requires a held provider-effect checkpoint and exact observation digest."
            )
        }

        let checkpoint: StorageAttachmentCheckpoint
        if record.checkpoint == .attachProviderEffectRequested {
            checkpoint = providerObservedAttached
                ? .attachProviderObserved
                : .attachFenceAcquired
        } else {
            checkpoint = providerObservedAttached
                ? .detachFenceAcquired
                : .detachProviderAbsentObserved
        }
        let resolved = try copy(
            record,
            checkpoint: checkpoint,
            providerObservationSHA256:
                providerObservationSHA256,
            clearAmbiguousHoldReason: true
        )
        return try replacing(
            resolved,
            in: ledger,
            disposition: .performed
        )
    }

    public func removeDetached(
        attachmentID: String,
        expectedAuthority: StorageAttachmentAuthority,
        from ledger: StorageAttachmentLedger
    ) throws -> StorageAttachmentLedger {
        guard let record = ledger.record(id: attachmentID) else {
            return ledger
        }
        try requireAuthority(expectedAuthority, record: record)
        guard record.checkpoint == .detachedCommitted else {
            throw failure(
                .invalidTransition,
                .never,
                "Only a committed detached record may be removed."
            )
        }
        return try StorageAttachmentLedger(
            records: ledger.records.filter { $0.id != attachmentID }
        )
    }

    public func forceDetachAuthorization(
        for record: StorageAttachmentRecord,
        validUntilUnixMilliseconds: Int64
    ) -> String {
        let fields = [
            "hostwright.storage.force-detach.v1",
            record.id,
            record.volumeID,
            record.nodeUUID,
            record.workloadUUID,
            String(record.authority.generation),
            record.authority.fencingToken,
            String(validUntilUnixMilliseconds),
        ]
        return Self.forceDetachAuthorizationPrefix +
            Self.sha256(fields.joined(separator: "\n"))
    }

    private func validate(_ intent: StorageAttachmentIntent) throws {
        guard StorageAttachmentValidation.validUUID(
            intent.attachmentID
        ),
        StorageAttachmentValidation.validUUID(intent.volumeID),
        StorageAttachmentValidation.validUUID(intent.nodeUUID),
        StorageAttachmentValidation.validUUID(intent.workloadUUID),
        StorageAttachmentValidation.validUUID(intent.operationID),
        StorageAttachmentValidation.validSHA256(
            intent.idempotencyKey
        ),
        intent.accessMode != .readOnlyMany || intent.readOnly else {
            throw failure(
                .invalidArgument,
                .never,
                "Attach intent contains an invalid identity, access mode, or idempotency key."
            )
        }
        _ = try leaseExpiry(
            durationMilliseconds: intent.leaseDurationMilliseconds
        )
    }

    private func validate(_ intent: StorageDetachIntent) throws {
        guard StorageAttachmentValidation.validUUID(
            intent.attachmentID
        ),
        StorageAttachmentValidation.validUUID(intent.holderNodeUUID),
        StorageAttachmentValidation.validUUID(
            intent.holderWorkloadUUID
        ),
        StorageAttachmentValidation.validUUID(intent.operationID),
        StorageAttachmentValidation.validSHA256(
            intent.idempotencyKey
        ) else {
            throw failure(
                .invalidArgument,
                .never,
                "Detach intent contains an invalid identity or idempotency key."
            )
        }
        _ = try leaseExpiry(
            durationMilliseconds: intent.leaseDurationMilliseconds
        )
    }

    private func leaseExpiry(
        durationMilliseconds: Int64
    ) throws -> Int64 {
        guard durationMilliseconds >=
            StorageAttachmentValidation.minimumLeaseMilliseconds,
            durationMilliseconds <=
            StorageAttachmentValidation.maximumLeaseMilliseconds else {
            throw failure(
                .invalidArgument,
                .never,
                "Attachment lease duration is outside the supported range."
            )
        }
        let result = nowUnixMilliseconds.addingReportingOverflow(
            durationMilliseconds
        )
        guard !result.overflow else {
            throw failure(
                .invalidArgument,
                .never,
                "Attachment lease expiry overflowed."
            )
        }
        return result.partialValue
    }

    private func isAttachReplay(
        _ intent: StorageAttachmentIntent,
        existing: StorageAttachmentRecord
    ) -> Bool {
        existing.operationID == intent.operationID &&
            existing.idempotencyKey == intent.idempotencyKey &&
            existing.volumeID == intent.volumeID &&
            existing.nodeUUID == intent.nodeUUID &&
            existing.workloadUUID == intent.workloadUUID &&
            existing.accessMode == intent.accessMode &&
            existing.readOnly == intent.readOnly &&
            existing.authority == intent.authority &&
            existing.checkpoint.isAttach
    }

    private func isDetachReplay(
        _ intent: StorageDetachIntent,
        existing: StorageAttachmentRecord
    ) -> Bool {
        existing.operationID == intent.operationID &&
            existing.idempotencyKey == intent.idempotencyKey &&
            existing.authority == intent.replacementAuthority &&
            !existing.checkpoint.isAttach
    }

    private func requireRecord(
        _ id: String,
        in ledger: StorageAttachmentLedger
    ) throws -> StorageAttachmentRecord {
        guard StorageAttachmentValidation.validUUID(id),
              let record = ledger.record(id: id) else {
            throw failure(
                .notFound,
                .safeAfterObservation,
                "The exact attachment identity was not found."
            )
        }
        return record
    }

    private func requireAuthority(
        _ expected: StorageAttachmentAuthority,
        record: StorageAttachmentRecord
    ) throws {
        guard expected.generation == record.authority.generation else {
            throw failure(
                .staleGeneration,
                .safeAfterObservation,
                "Attachment generation is stale."
            )
        }
        guard expected.fencingToken ==
            record.authority.fencingToken else {
            throw failure(
                .fencingConflict,
                .safeAfterObservation,
                "Attachment fencing token is stale."
            )
        }
    }

    private func requireSuccessor(
        _ replacement: StorageAttachmentAuthority,
        after existing: StorageAttachmentAuthority
    ) throws {
        let generation = existing.generation.addingReportingOverflow(1)
        guard !generation.overflow,
              replacement.generation == generation.partialValue,
              replacement.fencingToken !=
                existing.fencingToken else {
            throw failure(
                .staleGeneration,
                .safeAfterObservation,
                "New attachment authority must advance one generation with a new fence."
            )
        }
    }

    private func requireHolder(
        nodeUUID: String,
        workloadUUID: String,
        record: StorageAttachmentRecord
    ) throws {
        guard record.nodeUUID == nodeUUID,
              record.workloadUUID == workloadUUID else {
            throw failure(
                .holderConflict,
                .never,
                "Only the exact node and workload holder may perform this operation."
            )
        }
    }

    private func copy(
        _ record: StorageAttachmentRecord,
        checkpoint: StorageAttachmentCheckpoint? = nil,
        leaseRenewedAtUnixMilliseconds: Int64? = nil,
        leaseExpiresAtUnixMilliseconds: Int64? = nil,
        providerObservationSHA256: String? = nil,
        ambiguousHoldReason: String? = nil,
        clearAmbiguousHoldReason: Bool = false
    ) throws -> StorageAttachmentRecord {
        try StorageAttachmentRecord(
            id: record.id,
            volumeID: record.volumeID,
            nodeUUID: record.nodeUUID,
            workloadUUID: record.workloadUUID,
            accessMode: record.accessMode,
            readOnly: record.readOnly,
            authority: record.authority,
            operationID: record.operationID,
            idempotencyKey: record.idempotencyKey,
            checkpoint: checkpoint ?? record.checkpoint,
            leaseRenewedAtUnixMilliseconds:
                leaseRenewedAtUnixMilliseconds ??
                    record.leaseRenewedAtUnixMilliseconds,
            leaseExpiresAtUnixMilliseconds:
                leaseExpiresAtUnixMilliseconds ??
                    record.leaseExpiresAtUnixMilliseconds,
            providerObservationSHA256:
                providerObservationSHA256 ??
                    record.providerObservationSHA256,
            forceDetachAuthorizationSHA256:
                record.forceDetachAuthorizationSHA256,
            ambiguousHoldReason: clearAmbiguousHoldReason
                ? nil
                : ambiguousHoldReason ??
                    record.ambiguousHoldReason
        )
    }

    private func replacing(
        _ record: StorageAttachmentRecord,
        in ledger: StorageAttachmentLedger,
        disposition: StorageAttachmentDisposition
    ) throws -> StorageAttachmentTransition {
        let records = ledger.records.filter { $0.id != record.id } +
            [record]
        let updated = try StorageAttachmentLedger(records: records)
        return transition(
            disposition,
            record: record,
            ledger: updated
        )
    }

    private func transition(
        _ disposition: StorageAttachmentDisposition,
        record: StorageAttachmentRecord,
        ledger: StorageAttachmentLedger
    ) -> StorageAttachmentTransition {
        StorageAttachmentTransition(
            disposition: disposition,
            record: record,
            ledger: ledger
        )
    }

    private func failure(
        _ code: StorageAttachmentFailureCode,
        _ retryClass: StorageSemanticRetryClass,
        _ message: String
    ) -> StorageAttachmentFailure {
        StorageAttachmentFailure(
            code: code,
            retryClass: retryClass,
            message: message
        )
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
