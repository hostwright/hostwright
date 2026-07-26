import Foundation

public enum StorageAttachmentCheckpoint:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case attachIntentPersisted = "attach-intent-persisted"
    case attachFenceAcquired = "attach-fence-acquired"
    case attachProviderEffectRequested =
        "attach-provider-effect-requested"
    case attachProviderObserved = "attach-provider-observed"
    case attachedCommitted = "attached-committed"
    case detachIntentPersisted = "detach-intent-persisted"
    case detachFenceAcquired = "detach-fence-acquired"
    case detachProviderEffectRequested =
        "detach-provider-effect-requested"
    case detachProviderAbsentObserved =
        "detach-provider-absent-observed"
    case detachedCommitted = "detached-committed"

    public var next: StorageAttachmentCheckpoint? {
        switch self {
        case .attachIntentPersisted:
            .attachFenceAcquired
        case .attachFenceAcquired:
            .attachProviderEffectRequested
        case .attachProviderEffectRequested:
            .attachProviderObserved
        case .attachProviderObserved:
            .attachedCommitted
        case .attachedCommitted:
            nil
        case .detachIntentPersisted:
            .detachFenceAcquired
        case .detachFenceAcquired:
            .detachProviderEffectRequested
        case .detachProviderEffectRequested:
            .detachProviderAbsentObserved
        case .detachProviderAbsentObserved:
            .detachedCommitted
        case .detachedCommitted:
            nil
        }
    }

    public var isAttach: Bool {
        switch self {
        case .attachIntentPersisted,
             .attachFenceAcquired,
             .attachProviderEffectRequested,
             .attachProviderObserved,
             .attachedCommitted:
            true
        case .detachIntentPersisted,
             .detachFenceAcquired,
             .detachProviderEffectRequested,
             .detachProviderAbsentObserved,
             .detachedCommitted:
            false
        }
    }

    public var providerEffectMayBeAmbiguous: Bool {
        self == .attachProviderEffectRequested ||
            self == .detachProviderEffectRequested
    }
}

public enum StorageAttachmentLifecycleState:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case attaching
    case attached
    case detaching
    case detached
    case faulted
    case ambiguousHold = "ambiguous-hold"
}

public enum StorageAttachmentLeaseStatus:
    String,
    Codable,
    Sendable
{
    case active
    case stale
    case ambiguousHold = "ambiguous-hold"
    case detached
}

public enum StorageAttachmentInterruption:
    String,
    Codable,
    Sendable
{
    case none
    case cancelled
    case timedOut = "timed-out"
    case crashed
}

public enum StorageAttachmentDisposition:
    String,
    Codable,
    Sendable
{
    case performed
    case alreadySatisfied = "already-satisfied"
    case interrupted
    case held
}

public enum StorageAttachmentFailureCode:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case invalidArgument = "invalid-argument"
    case notFound = "not-found"
    case singleWriterConflict = "single-writer-conflict"
    case holderConflict = "holder-conflict"
    case staleGeneration = "stale-generation"
    case fencingConflict = "fencing-conflict"
    case leaseExpired = "lease-expired"
    case invalidTransition = "invalid-transition"
    case ambiguousHold = "ambiguous-hold"
    case authorizationRequired = "authorization-required"
    case authorizationExpired = "authorization-expired"
    case authorizationMismatch = "authorization-mismatch"
}

public struct StorageAttachmentFailure:
    Error,
    Codable,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    public let code: StorageAttachmentFailureCode
    public let retryClass: StorageSemanticRetryClass
    public let message: String

    public init(
        code: StorageAttachmentFailureCode,
        retryClass: StorageSemanticRetryClass,
        message: String
    ) {
        self.code = code
        self.retryClass = retryClass
        self.message = String(message.prefix(512))
    }

    public var description: String {
        "\(code.rawValue) (\(retryClass.rawValue)): \(message)"
    }
}

public struct StorageAttachmentAuthority:
    Codable,
    Equatable,
    Sendable
{
    public let generation: Int64
    public let fencingToken: String

    public init(generation: Int64, fencingToken: String) throws {
        guard generation > 0,
              StorageAttachmentValidation.validUUID(fencingToken) else {
            throw StorageAttachmentFailure(
                code: .invalidArgument,
                retryClass: .never,
                message: "Attachment authority requires a positive generation and canonical fencing UUID."
            )
        }
        self.generation = generation
        self.fencingToken = fencingToken
    }
}

public struct StorageAttachmentRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let volumeID: String
    public let nodeUUID: String
    public let workloadUUID: String
    public let accessMode: StorageSemanticAccessMode
    public let readOnly: Bool
    public let authority: StorageAttachmentAuthority
    public let operationID: String
    public let idempotencyKey: String
    public let checkpoint: StorageAttachmentCheckpoint
    public let leaseRenewedAtUnixMilliseconds: Int64
    public let leaseExpiresAtUnixMilliseconds: Int64
    public let providerObservationSHA256: String?
    public let forceDetachAuthorizationSHA256: String?
    public let ambiguousHoldReason: String?

    public init(
        id: String,
        volumeID: String,
        nodeUUID: String,
        workloadUUID: String,
        accessMode: StorageSemanticAccessMode,
        readOnly: Bool,
        authority: StorageAttachmentAuthority,
        operationID: String,
        idempotencyKey: String,
        checkpoint: StorageAttachmentCheckpoint,
        leaseRenewedAtUnixMilliseconds: Int64,
        leaseExpiresAtUnixMilliseconds: Int64,
        providerObservationSHA256: String? = nil,
        forceDetachAuthorizationSHA256: String? = nil,
        ambiguousHoldReason: String? = nil
    ) throws {
        self.id = id
        self.volumeID = volumeID
        self.nodeUUID = nodeUUID
        self.workloadUUID = workloadUUID
        self.accessMode = accessMode
        self.readOnly = readOnly
        self.authority = authority
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.checkpoint = checkpoint
        self.leaseRenewedAtUnixMilliseconds =
            leaseRenewedAtUnixMilliseconds
        self.leaseExpiresAtUnixMilliseconds =
            leaseExpiresAtUnixMilliseconds
        self.providerObservationSHA256 = providerObservationSHA256
        self.forceDetachAuthorizationSHA256 =
            forceDetachAuthorizationSHA256
        self.ambiguousHoldReason = ambiguousHoldReason
        try validate()
    }

    public var lifecycleState: StorageAttachmentLifecycleState {
        if ambiguousHoldReason != nil {
            return .ambiguousHold
        }
        switch checkpoint {
        case .attachIntentPersisted,
             .attachFenceAcquired,
             .attachProviderEffectRequested,
             .attachProviderObserved:
            return .attaching
        case .attachedCommitted:
            return .attached
        case .detachIntentPersisted,
             .detachFenceAcquired,
             .detachProviderEffectRequested,
             .detachProviderAbsentObserved:
            return .detaching
        case .detachedCommitted:
            return .detached
        }
    }

    public func leaseStatus(
        atUnixMilliseconds now: Int64
    ) -> StorageAttachmentLeaseStatus {
        if checkpoint == .detachedCommitted {
            return .detached
        }
        if ambiguousHoldReason != nil {
            return .ambiguousHold
        }
        return now < leaseExpiresAtUnixMilliseconds
            ? .active
            : .stale
    }

    func validate() throws {
        guard StorageAttachmentValidation.validUUID(id),
              StorageAttachmentValidation.validUUID(volumeID),
              StorageAttachmentValidation.validUUID(nodeUUID),
              StorageAttachmentValidation.validUUID(workloadUUID),
              StorageAttachmentValidation.validUUID(operationID),
              StorageAttachmentValidation.validSHA256(idempotencyKey),
              leaseRenewedAtUnixMilliseconds >= 0,
              leaseExpiresAtUnixMilliseconds >
                leaseRenewedAtUnixMilliseconds,
              accessMode != .readOnlyMany || readOnly,
              providerObservationSHA256 == nil ||
                StorageAttachmentValidation.validSHA256(
                    providerObservationSHA256!
                ),
              forceDetachAuthorizationSHA256 == nil ||
                StorageAttachmentValidation.validSHA256(
                    forceDetachAuthorizationSHA256!
                ),
              forceDetachAuthorizationSHA256 == nil ||
                !checkpoint.isAttach,
              ambiguousHoldReason == nil ||
                StorageAttachmentValidation.validReason(
                    ambiguousHoldReason!
                ),
              ambiguousHoldReason == nil ||
                checkpoint.providerEffectMayBeAmbiguous,
              ![
                StorageAttachmentCheckpoint.attachProviderObserved,
                .attachedCommitted,
                .detachProviderAbsentObserved,
                .detachedCommitted,
              ].contains(checkpoint) ||
                providerObservationSHA256 != nil else {
            throw StorageAttachmentFailure(
                code: .invalidArgument,
                retryClass: .never,
                message: "Attachment record contains an invalid identity, access mode, lease, digest, or hold."
            )
        }
    }
}

public struct StorageAttachmentLedger: Equatable, Sendable {
    public let records: [StorageAttachmentRecord]

    public init(records: [StorageAttachmentRecord] = []) throws {
        guard records.count <= StorageSemanticLimits.maximumResources,
              Set(records.map(\.id)).count == records.count else {
            throw StorageAttachmentFailure(
                code: .invalidArgument,
                retryClass: .never,
                message: "Attachment ledger is too large or has duplicate identities."
            )
        }
        for record in records {
            try record.validate()
        }
        let active = records.filter {
            $0.checkpoint != .detachedCommitted
        }
        let byVolume = Dictionary(grouping: active, by: \.volumeID)
        guard byVolume.values.allSatisfy({
            let writers = $0.filter { !$0.readOnly }
            return writers.isEmpty || $0.count == 1
        }) else {
            throw StorageAttachmentFailure(
                code: .singleWriterConflict,
                retryClass: .safeAfterObservation,
                message: "Attachment ledger contains a writer concurrently attached with another holder."
            )
        }
        let holders = Dictionary(grouping: active) {
            "\($0.volumeID):\($0.nodeUUID):\($0.workloadUUID)"
        }
        guard holders.values.allSatisfy({ $0.count <= 1 }) else {
            throw StorageAttachmentFailure(
                code: .holderConflict,
                retryClass: .safeAfterObservation,
                message: "Attachment ledger contains duplicate active holder identities."
            )
        }
        self.records = records.sorted { $0.id < $1.id }
    }

    public func record(id: String) -> StorageAttachmentRecord? {
        records.first { $0.id == id }
    }

    public func staleRecords(
        atUnixMilliseconds now: Int64
    ) -> [StorageAttachmentRecord] {
        records.filter {
            $0.leaseStatus(atUnixMilliseconds: now) == .stale
        }
    }
}

public struct StorageAttachmentIntent: Sendable {
    public let attachmentID: String
    public let volumeID: String
    public let nodeUUID: String
    public let workloadUUID: String
    public let accessMode: StorageSemanticAccessMode
    public let readOnly: Bool
    public let authority: StorageAttachmentAuthority
    public let expectedAuthority: StorageAttachmentAuthority?
    public let operationID: String
    public let idempotencyKey: String
    public let leaseDurationMilliseconds: Int64

    public init(
        attachmentID: String,
        volumeID: String,
        nodeUUID: String,
        workloadUUID: String,
        accessMode: StorageSemanticAccessMode,
        readOnly: Bool,
        authority: StorageAttachmentAuthority,
        expectedAuthority: StorageAttachmentAuthority? = nil,
        operationID: String,
        idempotencyKey: String,
        leaseDurationMilliseconds: Int64
    ) {
        self.attachmentID = attachmentID
        self.volumeID = volumeID
        self.nodeUUID = nodeUUID
        self.workloadUUID = workloadUUID
        self.accessMode = accessMode
        self.readOnly = readOnly
        self.authority = authority
        self.expectedAuthority = expectedAuthority
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.leaseDurationMilliseconds = leaseDurationMilliseconds
    }
}

public struct StorageDetachIntent: Sendable {
    public let attachmentID: String
    public let holderNodeUUID: String
    public let holderWorkloadUUID: String
    public let expectedAuthority: StorageAttachmentAuthority
    public let replacementAuthority: StorageAttachmentAuthority
    public let operationID: String
    public let idempotencyKey: String
    public let leaseDurationMilliseconds: Int64
    public let forceAuthorization: String?
    public let forceAuthorizationExpiresAtUnixMilliseconds: Int64?

    public init(
        attachmentID: String,
        holderNodeUUID: String,
        holderWorkloadUUID: String,
        expectedAuthority: StorageAttachmentAuthority,
        replacementAuthority: StorageAttachmentAuthority,
        operationID: String,
        idempotencyKey: String,
        leaseDurationMilliseconds: Int64,
        forceAuthorization: String? = nil,
        forceAuthorizationExpiresAtUnixMilliseconds: Int64? = nil
    ) {
        self.attachmentID = attachmentID
        self.holderNodeUUID = holderNodeUUID
        self.holderWorkloadUUID = holderWorkloadUUID
        self.expectedAuthority = expectedAuthority
        self.replacementAuthority = replacementAuthority
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.leaseDurationMilliseconds = leaseDurationMilliseconds
        self.forceAuthorization = forceAuthorization
        self.forceAuthorizationExpiresAtUnixMilliseconds =
            forceAuthorizationExpiresAtUnixMilliseconds
    }
}

public struct StorageAttachmentTransition: Equatable, Sendable {
    public let disposition: StorageAttachmentDisposition
    public let record: StorageAttachmentRecord
    public let ledger: StorageAttachmentLedger

    public init(
        disposition: StorageAttachmentDisposition,
        record: StorageAttachmentRecord,
        ledger: StorageAttachmentLedger
    ) {
        self.disposition = disposition
        self.record = record
        self.ledger = ledger
    }
}

enum StorageAttachmentValidation {
    static let minimumLeaseMilliseconds: Int64 = 1_000
    static let maximumLeaseMilliseconds: Int64 = 15 * 60 * 1_000

    static func validUUID(_ value: String) -> Bool {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }

    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 &&
            value.allSatisfy {
                ("0"..."9").contains($0) ||
                    ("a"..."f").contains($0)
            }
    }

    static func validReason(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= 512 &&
            value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}
