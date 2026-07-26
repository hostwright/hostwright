import CryptoKit
import Foundation

public struct StoragePressureThresholds:
    Codable,
    Equatable,
    Sendable
{
    public static let standard = StoragePressureThresholds(
        standardValues: ()
    )

    public let warningAvailableBasisPoints: Int
    public let criticalAvailableBasisPoints: Int
    public let emergencyAvailableBasisPoints: Int
    public let hysteresisBasisPoints: Int

    public init(
        warningAvailableBasisPoints: Int = 2_000,
        criticalAvailableBasisPoints: Int = 1_000,
        emergencyAvailableBasisPoints: Int = 500,
        hysteresisBasisPoints: Int = 250
    ) throws {
        guard emergencyAvailableBasisPoints >= 0,
              emergencyAvailableBasisPoints <
                criticalAvailableBasisPoints,
              criticalAvailableBasisPoints <
                warningAvailableBasisPoints,
              warningAvailableBasisPoints <= 10_000,
              hysteresisBasisPoints > 0,
              warningAvailableBasisPoints +
                hysteresisBasisPoints <= 10_000 else {
            throw StorageCapacityError(
                code: .invalidArgument,
                retryDisposition: .never,
                message:
                    "Pressure thresholds must be ordered bounded basis points with positive hysteresis."
            )
        }
        self.warningAvailableBasisPoints =
            warningAvailableBasisPoints
        self.criticalAvailableBasisPoints =
            criticalAvailableBasisPoints
        self.emergencyAvailableBasisPoints =
            emergencyAvailableBasisPoints
        self.hysteresisBasisPoints = hysteresisBasisPoints
    }

    private init(standardValues: Void) {
        warningAvailableBasisPoints = 2_000
        criticalAvailableBasisPoints = 1_000
        emergencyAvailableBasisPoints = 500
        hysteresisBasisPoints = 250
    }

    public var digestSHA256: String {
        Self.sha256([
            "hostwright.storage.pressure-policy.v1",
            String(warningAvailableBasisPoints),
            String(criticalAvailableBasisPoints),
            String(emergencyAvailableBasisPoints),
            String(hysteresisBasisPoints),
        ].joined(separator: "\n"))
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct StorageCapacityPolicy: Sendable {
    public let thresholds: StoragePressureThresholds

    public init(
        thresholds: StoragePressureThresholds = .standard
    ) {
        self.thresholds = thresholds
    }

    public func pressure(
        for sample: StorageCapacitySample,
        previous: StoragePressureLevel
    ) -> StoragePressureLevel {
        let availableBasisPoints = min(
            Self.basisPoints(
                available: sample.effectiveAvailableBytes,
                total: sample.totalBytes
            ),
            Self.basisPoints(
                available: sample.effectiveAvailableInodes,
                total: sample.totalInodes
            )
        )
        let raw = rawPressure(
            availableBasisPoints: availableBasisPoints
        )
        guard raw < previous else { return raw }

        let exitThreshold: Int
        switch previous {
        case .normal:
            return raw
        case .warning:
            exitThreshold =
                thresholds.warningAvailableBasisPoints +
                thresholds.hysteresisBasisPoints
        case .critical:
            exitThreshold =
                thresholds.criticalAvailableBasisPoints +
                thresholds.hysteresisBasisPoints
        case .emergency:
            exitThreshold =
                thresholds.emergencyAvailableBasisPoints +
                thresholds.hysteresisBasisPoints
        }
        return availableBasisPoints > exitThreshold
            ? raw
            : previous
    }

    public func evaluate(
        _ request: StorageCapacityAdmissionRequest,
        sample: StorageCapacitySample,
        previousPressure: StoragePressureLevel,
        atUnixMilliseconds now: Int64
    ) -> StorageCapacityAdmissionResult {
        let effectiveBytes = sample.effectiveAvailableBytes
        let effectiveInodes = sample.effectiveAvailableInodes
        let currentPressure = pressure(
            for: sample,
            previous: previousPressure
        )

        switch request.interruption {
        case .none:
            break
        case .cancelled:
            return result(
                request,
                disposition: .cancelled,
                reason: .cancelled,
                pressure: currentPressure,
                retry: .never,
                checkpoint: .cancelled,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        case .timedOut:
            return retryableResult(
                request,
                reason: .timedOut,
                pressure: currentPressure,
                checkpoint: .admissionPending,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        case .ambiguousEffect:
            return result(
                request,
                disposition: .recoveryRequired,
                reason: .ambiguousEffect,
                pressure: currentPressure,
                retry: .resumeFromCheckpoint,
                checkpoint: .observationRequired,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        }

        guard sample.isFresh(atUnixMilliseconds: now) else {
            return retryableResult(
                request,
                reason: .staleSample,
                pressure: currentPressure,
                checkpoint: .admissionPending,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        }
        if request.requiresHardQuota,
           sample.quotaCapability.mode != .hard {
            return result(
                request,
                disposition: .reject,
                reason: .hardQuotaUnavailable,
                pressure: currentPressure,
                retry: .never,
                checkpoint: .rejected,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        }
        if exceedsQuota(
            used: request.quotaUsedBytes,
            growth: request.additionalBytes,
            limit: request.quotaLimitBytes
        ) || exceedsQuota(
            used: request.quotaUsedInodes,
            growth: request.additionalInodes,
            limit: request.quotaLimitInodes
        ) {
            return result(
                request,
                disposition: .reject,
                reason: .quotaExceeded,
                pressure: currentPressure,
                retry: .never,
                checkpoint: .rejected,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        }
        guard request.additionalBytes <= effectiveBytes else {
            return retryableResult(
                request,
                reason: .bytesExhausted,
                pressure: currentPressure,
                checkpoint: .rejected,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        }
        guard request.additionalInodes <= effectiveInodes else {
            return retryableResult(
                request,
                reason: .inodesExhausted,
                pressure: currentPressure,
                checkpoint: .rejected,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        }

        let remainingBytes =
            effectiveBytes - request.additionalBytes
        let remainingInodes =
            effectiveInodes - request.additionalInodes
        let predictedBasisPoints = min(
            Self.basisPoints(
                available: remainingBytes,
                total: sample.totalBytes
            ),
            Self.basisPoints(
                available: remainingInodes,
                total: sample.totalInodes
            )
        )
        let predictedPressure = max(
            currentPressure,
            rawPressure(
                availableBasisPoints: predictedBasisPoints
            )
        )

        if predictedPressure == .emergency,
           request.action.canGrowStorage ||
            (request.action == .attach && request.writable) {
            return retryableResult(
                request,
                reason: .emergencyPressure,
                pressure: predictedPressure,
                checkpoint: .rejected,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        }
        if predictedPressure == .critical,
           request.action.canGrowStorage ||
            (request.action == .attach && request.writable) {
            return retryableResult(
                request,
                reason: .criticalPressure,
                pressure: predictedPressure,
                checkpoint: .throttled,
                availableBytes: effectiveBytes,
                availableInodes: effectiveInodes
            )
        }
        return result(
            request,
            disposition: .admit,
            reason: predictedPressure == .warning
                ? .warningPressure
                : .admitted,
            pressure: predictedPressure,
            retry: .never,
            checkpoint: .admitted,
            availableBytes: effectiveBytes,
            availableInodes: effectiveInodes
        )
    }

    public func planGarbageCollection(
        candidates: [StorageGCCandidate],
        targetBytes: Int64,
        targetInodes: Int64,
        maximumItems: Int,
        sampleDigestSHA256: String,
        policyDigestSHA256: String? = nil,
        cancelled: Bool = false
    ) throws -> StorageGCPlan {
        guard candidates.count <=
                StorageCapacityLimits.maximumGCCandidates,
              (0...StorageCapacityLimits.maximumBytes)
                .contains(targetBytes),
              (0...StorageCapacityLimits.maximumInodes)
                .contains(targetInodes),
              maximumItems >= 1,
              maximumItems <=
                StorageCapacityLimits.maximumGCSelection,
              StorageCapacityValidation.validSHA256(
                  sampleDigestSHA256
              ),
              policyDigestSHA256 == nil ||
                StorageCapacityValidation.validSHA256(
                    policyDigestSHA256!
                ),
              Set(candidates.map(\.resourceID)).count ==
                candidates.count else {
            throw StorageCapacityError(
                code: .invalidArgument,
                retryDisposition: .never,
                message:
                    "GC request exceeds bounded targets, identities, or candidate limits."
            )
        }
        let effectivePolicyDigest =
            policyDigestSHA256 ?? thresholds.digestSHA256
        if cancelled {
            return StorageGCPlan(
                selected: [],
                reclaimedBytes: 0,
                reclaimedInodes: 0,
                targetBytes: targetBytes,
                targetInodes: targetInodes,
                targetSatisfied:
                    targetBytes == 0 && targetInodes == 0,
                cancelled: true,
                sampleDigestSHA256: sampleDigestSHA256,
                policyDigestSHA256: effectivePolicyDigest,
                confirmationSHA256: Self.gcConfirmation(
                    selected: [],
                    sampleDigestSHA256: sampleDigestSHA256,
                    policyDigestSHA256:
                        effectivePolicyDigest,
                    targetBytes: targetBytes,
                    targetInodes: targetInodes
                )
            )
        }

        let ordered = candidates.filter(\.isEligible).sorted {
            (
                $0.kind.priority,
                $0.lastUsedAtUnixMilliseconds,
                -$0.reclaimableBytes,
                -$0.reclaimableInodes,
                $0.resourceID
            ) < (
                $1.kind.priority,
                $1.lastUsedAtUnixMilliseconds,
                -$1.reclaimableBytes,
                -$1.reclaimableInodes,
                $1.resourceID
            )
        }
        var selected: [StorageGCCandidate] = []
        var bytes: Int64 = 0
        var inodes: Int64 = 0
        for candidate in ordered {
            if targetsSatisfied(
                bytes: bytes,
                inodes: inodes,
                targetBytes: targetBytes,
                targetInodes: targetInodes
            ) || selected.count == maximumItems {
                break
            }
            selected.append(candidate)
            bytes = Self.saturatingAdd(
                bytes,
                candidate.reclaimableBytes,
                maximum: StorageCapacityLimits.maximumBytes
            )
            inodes = Self.saturatingAdd(
                inodes,
                candidate.reclaimableInodes,
                maximum: StorageCapacityLimits.maximumInodes
            )
        }
        return StorageGCPlan(
            selected: selected,
            reclaimedBytes: bytes,
            reclaimedInodes: inodes,
            targetBytes: targetBytes,
            targetInodes: targetInodes,
            targetSatisfied: targetsSatisfied(
                bytes: bytes,
                inodes: inodes,
                targetBytes: targetBytes,
                targetInodes: targetInodes
            ),
            cancelled: false,
            sampleDigestSHA256: sampleDigestSHA256,
            policyDigestSHA256: effectivePolicyDigest,
            confirmationSHA256: Self.gcConfirmation(
                selected: selected,
                sampleDigestSHA256: sampleDigestSHA256,
                policyDigestSHA256: effectivePolicyDigest,
                targetBytes: targetBytes,
                targetInodes: targetInodes
            )
        )
    }

    private func rawPressure(
        availableBasisPoints: Int
    ) -> StoragePressureLevel {
        if availableBasisPoints <=
            thresholds.emergencyAvailableBasisPoints {
            return .emergency
        }
        if availableBasisPoints <=
            thresholds.criticalAvailableBasisPoints {
            return .critical
        }
        if availableBasisPoints <=
            thresholds.warningAvailableBasisPoints {
            return .warning
        }
        return .normal
    }

    private func retryableResult(
        _ request: StorageCapacityAdmissionRequest,
        reason: StorageCapacityReason,
        pressure: StoragePressureLevel,
        checkpoint: StorageCapacityRecoveryCheckpoint,
        availableBytes: Int64,
        availableInodes: Int64
    ) -> StorageCapacityAdmissionResult {
        if request.attempt >= request.maximumAttempts {
            return result(
                request,
                disposition: .reject,
                reason: .retryExhausted,
                pressure: pressure,
                retry: .never,
                checkpoint: .rejected,
                availableBytes: availableBytes,
                availableInodes: availableInodes
            )
        }
        return result(
            request,
            disposition: checkpoint == .throttled
                ? .throttle
                : .reject,
            reason: reason,
            pressure: pressure,
            retry: .afterFreshSample,
            checkpoint: checkpoint,
            availableBytes: availableBytes,
            availableInodes: availableInodes
        )
    }

    private func result(
        _ request: StorageCapacityAdmissionRequest,
        disposition: StorageAdmissionDisposition,
        reason: StorageCapacityReason,
        pressure: StoragePressureLevel,
        retry: StorageCapacityRetryDisposition,
        checkpoint: StorageCapacityRecoveryCheckpoint,
        availableBytes: Int64,
        availableInodes: Int64
    ) -> StorageCapacityAdmissionResult {
        StorageCapacityAdmissionResult(
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            disposition: disposition,
            reason: reason,
            pressure: pressure,
            retryDisposition: retry,
            checkpoint: checkpoint,
            attempt: request.attempt,
            effectiveAvailableBytes: availableBytes,
            effectiveAvailableInodes: availableInodes
        )
    }

    private func exceedsQuota(
        used: Int64,
        growth: Int64,
        limit: Int64?
    ) -> Bool {
        guard let limit else { return false }
        let sum = used.addingReportingOverflow(growth)
        return sum.overflow || sum.partialValue > limit
    }

    private func targetsSatisfied(
        bytes: Int64,
        inodes: Int64,
        targetBytes: Int64,
        targetInodes: Int64
    ) -> Bool {
        bytes >= targetBytes && inodes >= targetInodes
    }

    private static func saturatingAdd(
        _ lhs: Int64,
        _ rhs: Int64,
        maximum: Int64
    ) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow
            ? maximum
            : min(maximum, result.partialValue)
    }

    private static func basisPoints(
        available: Int64,
        total: Int64
    ) -> Int {
        guard total > 0, available > 0 else { return 0 }
        guard available < total else { return 10_000 }
        let product = UInt64(available)
            .multipliedFullWidth(by: 10_000)
        let quotient = UInt64(total)
            .dividingFullWidth(product).quotient
        return Int(min(quotient, 10_000))
    }

    private static func gcConfirmation(
        selected: [StorageGCCandidate],
        sampleDigestSHA256: String,
        policyDigestSHA256: String,
        targetBytes: Int64,
        targetInodes: Int64
    ) -> String {
        var fields = [
            "hostwright.storage.gc-priority-plan.v1",
            sampleDigestSHA256,
            policyDigestSHA256,
            String(targetBytes),
            String(targetInodes),
        ]
        for candidate in selected {
            fields.append(
                [
                    candidate.resourceID,
                    candidate.kind.rawValue,
                    String(candidate.generation),
                    candidate.fencingToken,
                    candidate.ownershipProofSHA256 ?? "",
                    candidate.disruptionPolicySHA256,
                    String(candidate.reclaimableBytes),
                    String(candidate.reclaimableInodes),
                ].joined(separator: ":")
            )
        }
        return SHA256.hash(
            data: Data(fields.joined(separator: "\n").utf8)
        ).map { String(format: "%02x", $0) }.joined()
    }
}
