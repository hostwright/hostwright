import CryptoKit
import Foundation

public enum StorageCapacityLimits {
    public static let maximumBytes: Int64 =
        StorageSemanticLimits.maximumCapacityBytes
    public static let maximumInodes: Int64 =
        9_007_199_254_740_991
    public static let maximumSampleLifetimeMilliseconds: Int64 =
        15 * 60 * 1_000
    public static let maximumRetryAttempts = 3
    public static let maximumGCCandidates =
        StorageSemanticLimits.maximumResources
    public static let maximumGCSelection = 256
}

public enum StorageQuotaEnforcementMode:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case hard
    case logical
    case unavailable
}

public struct StorageQuotaCapability:
    Codable,
    Equatable,
    Sendable
{
    public let mode: StorageQuotaEnforcementMode
    public let evidenceSHA256: String?

    public init(
        mode: StorageQuotaEnforcementMode,
        evidenceSHA256: String? = nil
    ) throws {
        guard evidenceSHA256 == nil ||
                StorageCapacityValidation.validSHA256(
                    evidenceSHA256!
                ),
              mode != .hard || evidenceSHA256 != nil else {
            throw StorageCapacityError(
                code: .invalidArgument,
                retryDisposition: .never,
                message:
                    "Hard quota enforcement requires exact provider evidence."
            )
        }
        self.mode = mode
        self.evidenceSHA256 = evidenceSHA256
    }
}

public enum StorageCapacitySampleSource:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case statfs
    case provider
    case reconciledState = "reconciled-state"
}

public enum StoragePressureLevel:
    String,
    Codable,
    CaseIterable,
    Comparable,
    Sendable
{
    case normal
    case warning
    case critical
    case emergency

    private var rank: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        case .emergency: 3
        }
    }

    public static func < (
        lhs: StoragePressureLevel,
        rhs: StoragePressureLevel
    ) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct StorageCapacitySample:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let providerID: String
    public let topologyNodeID: String
    public let source: StorageCapacitySampleSource
    public let requestedBytes: Int64
    public let reservedBytes: Int64
    public let usedBytes: Int64
    public let reclaimableBytes: Int64
    public let availableBytes: Int64
    public let totalBytes: Int64
    public let requestedInodes: Int64
    public let reservedInodes: Int64
    public let usedInodes: Int64
    public let reclaimableInodes: Int64
    public let availableInodes: Int64
    public let totalInodes: Int64
    public let quotaCapability: StorageQuotaCapability
    public let capturedAtUnixMilliseconds: Int64
    public let validUntilUnixMilliseconds: Int64

    public init(
        id: String,
        providerID: String,
        topologyNodeID: String,
        source: StorageCapacitySampleSource,
        requestedBytes: Int64,
        reservedBytes: Int64,
        usedBytes: Int64,
        reclaimableBytes: Int64,
        availableBytes: Int64,
        totalBytes: Int64,
        requestedInodes: Int64,
        reservedInodes: Int64,
        usedInodes: Int64,
        reclaimableInodes: Int64,
        availableInodes: Int64,
        totalInodes: Int64,
        quotaCapability: StorageQuotaCapability,
        capturedAtUnixMilliseconds: Int64,
        validUntilUnixMilliseconds: Int64
    ) throws {
        self.id = id
        self.providerID = providerID
        self.topologyNodeID = topologyNodeID
        self.source = source
        self.requestedBytes = requestedBytes
        self.reservedBytes = reservedBytes
        self.usedBytes = usedBytes
        self.reclaimableBytes = reclaimableBytes
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.requestedInodes = requestedInodes
        self.reservedInodes = reservedInodes
        self.usedInodes = usedInodes
        self.reclaimableInodes = reclaimableInodes
        self.availableInodes = availableInodes
        self.totalInodes = totalInodes
        self.quotaCapability = quotaCapability
        self.capturedAtUnixMilliseconds =
            capturedAtUnixMilliseconds
        self.validUntilUnixMilliseconds =
            validUntilUnixMilliseconds
        try validate()
    }

    public var effectiveAvailableBytes: Int64 {
        max(0, availableBytes - reservedBytes)
    }

    public var effectiveAvailableInodes: Int64 {
        max(0, availableInodes - reservedInodes)
    }

    public func isFresh(
        atUnixMilliseconds now: Int64
    ) -> Bool {
        now >= capturedAtUnixMilliseconds &&
            now <= validUntilUnixMilliseconds
    }

    public var digestSHA256: String {
        let fields = [
            "hostwright.storage.capacity-sample.v1",
            id,
            providerID,
            topologyNodeID,
            source.rawValue,
            String(requestedBytes),
            String(reservedBytes),
            String(usedBytes),
            String(reclaimableBytes),
            String(availableBytes),
            String(totalBytes),
            String(requestedInodes),
            String(reservedInodes),
            String(usedInodes),
            String(reclaimableInodes),
            String(availableInodes),
            String(totalInodes),
            quotaCapability.mode.rawValue,
            quotaCapability.evidenceSHA256 ?? "",
            String(capturedAtUnixMilliseconds),
            String(validUntilUnixMilliseconds),
        ]
        return Self.sha256(fields.joined(separator: "\n"))
    }

    private func validate() throws {
        let bytes = [
            requestedBytes,
            reservedBytes,
            usedBytes,
            reclaimableBytes,
            availableBytes,
            totalBytes,
        ]
        let inodes = [
            requestedInodes,
            reservedInodes,
            usedInodes,
            reclaimableInodes,
            availableInodes,
            totalInodes,
        ]
        let lifetime = validUntilUnixMilliseconds
            .subtractingReportingOverflow(
                capturedAtUnixMilliseconds
            )
        guard StorageCapacityValidation.validUUID(id),
              StorageCapacityValidation.validIdentifier(
                  providerID,
                  maximumBytes:
                    StorageSemanticLimits.maximumProviderIDBytes
              ),
              StorageCapacityValidation.validIdentifier(
                  topologyNodeID,
                  maximumBytes:
                    StorageSemanticLimits.maximumNameBytes
              ),
              bytes.allSatisfy({
                  (0...StorageCapacityLimits.maximumBytes)
                    .contains($0)
              }),
              inodes.allSatisfy({
                  (0...StorageCapacityLimits.maximumInodes)
                    .contains($0)
              }),
              totalBytes > 0,
              totalInodes > 0,
              usedBytes <= totalBytes,
              availableBytes <= totalBytes,
              reclaimableBytes <= usedBytes,
              usedBytes <= totalBytes - availableBytes,
              usedInodes <= totalInodes,
              availableInodes <= totalInodes,
              reclaimableInodes <= usedInodes,
              usedInodes <= totalInodes - availableInodes,
              !lifetime.overflow,
              lifetime.partialValue > 0,
              lifetime.partialValue <=
                StorageCapacityLimits
                    .maximumSampleLifetimeMilliseconds else {
            throw StorageCapacityError(
                code: .invalidSample,
                retryDisposition: .afterFreshSample,
                message:
                    "Capacity sample contains invalid identity, accounting, or freshness bounds."
            )
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum StorageCapacityAction:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case create
    case expand
    case attach
    case restore
    case snapshot
    case backup
    case garbageCollect = "garbage-collect"

    public var canGrowStorage: Bool {
        switch self {
        case .create, .expand, .restore, .snapshot, .backup:
            true
        case .attach, .garbageCollect:
            false
        }
    }
}

public enum StorageCapacityInterruption:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case none
    case cancelled
    case timedOut = "timed-out"
    case ambiguousEffect = "ambiguous-effect"
}

public struct StorageCapacityAdmissionRequest:
    Codable,
    Equatable,
    Sendable
{
    public let operationID: String
    public let idempotencyKey: String
    public let action: StorageCapacityAction
    public let additionalBytes: Int64
    public let additionalInodes: Int64
    public let writable: Bool
    public let requiresHardQuota: Bool
    public let quotaUsedBytes: Int64
    public let quotaUsedInodes: Int64
    public let quotaLimitBytes: Int64?
    public let quotaLimitInodes: Int64?
    public let attempt: Int
    public let maximumAttempts: Int
    public let interruption: StorageCapacityInterruption

    public init(
        operationID: String,
        idempotencyKey: String,
        action: StorageCapacityAction,
        additionalBytes: Int64,
        additionalInodes: Int64,
        writable: Bool,
        requiresHardQuota: Bool = false,
        quotaUsedBytes: Int64 = 0,
        quotaUsedInodes: Int64 = 0,
        quotaLimitBytes: Int64? = nil,
        quotaLimitInodes: Int64? = nil,
        attempt: Int = 1,
        maximumAttempts: Int =
            StorageCapacityLimits.maximumRetryAttempts,
        interruption: StorageCapacityInterruption = .none
    ) throws {
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.action = action
        self.additionalBytes = additionalBytes
        self.additionalInodes = additionalInodes
        self.writable = writable
        self.requiresHardQuota = requiresHardQuota
        self.quotaUsedBytes = quotaUsedBytes
        self.quotaUsedInodes = quotaUsedInodes
        self.quotaLimitBytes = quotaLimitBytes
        self.quotaLimitInodes = quotaLimitInodes
        self.attempt = attempt
        self.maximumAttempts = maximumAttempts
        self.interruption = interruption
        try validate()
    }

    private func validate() throws {
        guard StorageCapacityValidation.validUUID(operationID),
              StorageCapacityValidation.validSHA256(
                  idempotencyKey
              ),
              (0...StorageCapacityLimits.maximumBytes)
                .contains(additionalBytes),
              (0...StorageCapacityLimits.maximumInodes)
                .contains(additionalInodes),
              (0...StorageCapacityLimits.maximumBytes)
                .contains(quotaUsedBytes),
              (0...StorageCapacityLimits.maximumInodes)
                .contains(quotaUsedInodes),
              quotaLimitBytes == nil ||
                (0...StorageCapacityLimits.maximumBytes)
                    .contains(quotaLimitBytes!),
              quotaLimitInodes == nil ||
                (0...StorageCapacityLimits.maximumInodes)
                    .contains(quotaLimitInodes!),
              attempt >= 1,
              maximumAttempts >= 1,
              maximumAttempts <=
                StorageCapacityLimits.maximumRetryAttempts,
              attempt <= maximumAttempts,
              action.canGrowStorage ||
                (additionalBytes == 0 && additionalInodes == 0)
        else {
            throw StorageCapacityError(
                code: .invalidArgument,
                retryDisposition: .never,
                message:
                    "Capacity admission request is outside bounded operation, quota, or retry limits."
            )
        }
    }
}

public enum StorageAdmissionDisposition:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case admit
    case throttle
    case reject
    case cancelled
    case recoveryRequired = "recovery-required"
}

public enum StorageCapacityReason:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case admitted
    case warningPressure = "warning-pressure"
    case criticalPressure = "critical-pressure"
    case emergencyPressure = "emergency-pressure"
    case staleSample = "stale-sample"
    case bytesExhausted = "bytes-exhausted"
    case inodesExhausted = "inodes-exhausted"
    case quotaExceeded = "quota-exceeded"
    case hardQuotaUnavailable = "hard-quota-unavailable"
    case retryExhausted = "retry-exhausted"
    case cancelled
    case timedOut = "timed-out"
    case ambiguousEffect = "ambiguous-effect"
}

public enum StorageCapacityRetryDisposition:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case never
    case afterFreshSample = "after-fresh-sample"
    case resumeFromCheckpoint = "resume-from-checkpoint"
}

public enum StorageCapacityRecoveryCheckpoint:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case admissionPending = "admission-pending"
    case sampleValidated = "sample-validated"
    case admitted
    case throttled
    case rejected
    case cancelled
    case observationRequired = "observation-required"
}

public struct StorageCapacityAdmissionResult:
    Codable,
    Equatable,
    Sendable
{
    public let operationID: String
    public let idempotencyKey: String
    public let disposition: StorageAdmissionDisposition
    public let reason: StorageCapacityReason
    public let pressure: StoragePressureLevel
    public let retryDisposition:
        StorageCapacityRetryDisposition
    public let checkpoint: StorageCapacityRecoveryCheckpoint
    public let attempt: Int
    public let effectiveAvailableBytes: Int64
    public let effectiveAvailableInodes: Int64

    public init(
        operationID: String,
        idempotencyKey: String,
        disposition: StorageAdmissionDisposition,
        reason: StorageCapacityReason,
        pressure: StoragePressureLevel,
        retryDisposition: StorageCapacityRetryDisposition,
        checkpoint: StorageCapacityRecoveryCheckpoint,
        attempt: Int,
        effectiveAvailableBytes: Int64,
        effectiveAvailableInodes: Int64
    ) {
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.disposition = disposition
        self.reason = reason
        self.pressure = pressure
        self.retryDisposition = retryDisposition
        self.checkpoint = checkpoint
        self.attempt = attempt
        self.effectiveAvailableBytes = effectiveAvailableBytes
        self.effectiveAvailableInodes =
            effectiveAvailableInodes
    }
}

public enum StorageCapacityErrorCode:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case invalidArgument = "invalid-argument"
    case invalidSample = "invalid-sample"
    case arithmeticOverflow = "arithmetic-overflow"
    case probeFailed = "probe-failed"
}

public struct StorageCapacityError:
    Error,
    Codable,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    public let code: StorageCapacityErrorCode
    public let retryDisposition:
        StorageCapacityRetryDisposition
    public let message: String

    public init(
        code: StorageCapacityErrorCode,
        retryDisposition: StorageCapacityRetryDisposition,
        message: String
    ) {
        self.code = code
        self.retryDisposition = retryDisposition
        self.message = String(message.prefix(512))
    }

    public var description: String {
        "\(code.rawValue) (\(retryDisposition.rawValue)): \(message)"
    }
}

public enum StorageGCCandidateKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case orphan
    case backup
    case snapshot
    case volume

    var priority: Int {
        switch self {
        case .orphan: 0
        case .backup: 1
        case .snapshot: 2
        case .volume: 3
        }
    }
}

public enum StorageCapacityReclaimPolicy:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case retain
    case delete
}

public struct StorageGCCandidate:
    Codable,
    Equatable,
    Sendable
{
    public let resourceID: String
    public let kind: StorageGCCandidateKind
    public let reclaimPolicy: StorageCapacityReclaimPolicy
    public let reclaimableBytes: Int64
    public let reclaimableInodes: Int64
    public let hasActiveHold: Bool
    public let hasActiveAttachment: Bool
    public let disruptionBudgetAllows: Bool
    public let ownershipProofSHA256: String?
    public let disruptionPolicySHA256: String
    public let generation: Int64
    public let fencingToken: String
    public let lastUsedAtUnixMilliseconds: Int64

    public init(
        resourceID: String,
        kind: StorageGCCandidateKind,
        reclaimPolicy: StorageCapacityReclaimPolicy,
        reclaimableBytes: Int64,
        reclaimableInodes: Int64,
        hasActiveHold: Bool,
        hasActiveAttachment: Bool,
        disruptionBudgetAllows: Bool,
        ownershipProofSHA256: String?,
        disruptionPolicySHA256: String,
        generation: Int64,
        fencingToken: String,
        lastUsedAtUnixMilliseconds: Int64
    ) throws {
        guard StorageCapacityValidation.validUUID(resourceID),
              (0...StorageCapacityLimits.maximumBytes)
                .contains(reclaimableBytes),
              (0...StorageCapacityLimits.maximumInodes)
                .contains(reclaimableInodes),
              ownershipProofSHA256 == nil ||
                StorageCapacityValidation.validSHA256(
                    ownershipProofSHA256!
                ),
              StorageCapacityValidation.validSHA256(
                  disruptionPolicySHA256
              ),
              generation > 0,
              StorageCapacityValidation.validUUID(fencingToken),
              lastUsedAtUnixMilliseconds >= 0 else {
            throw StorageCapacityError(
                code: .invalidArgument,
                retryDisposition: .never,
                message: "GC candidate is outside bounded identity or accounting limits."
            )
        }
        self.resourceID = resourceID
        self.kind = kind
        self.reclaimPolicy = reclaimPolicy
        self.reclaimableBytes = reclaimableBytes
        self.reclaimableInodes = reclaimableInodes
        self.hasActiveHold = hasActiveHold
        self.hasActiveAttachment = hasActiveAttachment
        self.disruptionBudgetAllows = disruptionBudgetAllows
        self.ownershipProofSHA256 = ownershipProofSHA256
        self.disruptionPolicySHA256 =
            disruptionPolicySHA256
        self.generation = generation
        self.fencingToken = fencingToken
        self.lastUsedAtUnixMilliseconds =
            lastUsedAtUnixMilliseconds
    }

    public var isEligible: Bool {
        reclaimPolicy == .delete &&
            !hasActiveHold &&
            !hasActiveAttachment &&
            disruptionBudgetAllows &&
            ownershipProofSHA256 != nil &&
            (reclaimableBytes > 0 || reclaimableInodes > 0)
    }
}

public struct StorageGCPlan:
    Codable,
    Equatable,
    Sendable
{
    public let selected: [StorageGCCandidate]
    public let reclaimedBytes: Int64
    public let reclaimedInodes: Int64
    public let targetBytes: Int64
    public let targetInodes: Int64
    public let targetSatisfied: Bool
    public let cancelled: Bool
    public let sampleDigestSHA256: String
    public let policyDigestSHA256: String
    public let confirmationSHA256: String
}

enum StorageCapacityValidation {
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

    static func validIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn:
                        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"
                ).contains($0)
            }
    }
}
