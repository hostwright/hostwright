import Foundation

/// Applies one caller-observed reclamation transition without owning time or
/// mutating a VM. The returned intent is the complete next state.
public struct VMReclamationStateMachine: Sendable {
    public let configuration: VMReclamationConfiguration

    public init(configuration: VMReclamationConfiguration = .standard) {
        self.configuration = configuration
    }

    public func transition(
        intent: VMReclamationIntent,
        request: VMReclamationTransitionRequest
    ) -> VMReclamationResult {
        if intent.configurationVersion != configuration.version
            || intent.stabilitySampleCount != configuration.stabilitySampleCount {
            return rejection(
                intent: intent,
                errorCode: .configurationMismatch,
                observedAt: request.observedAt
            )
        }

        if intent.ownership != .hostwrightOwned {
            return rejection(
                intent: intent,
                errorCode: .unmanagedOwnership,
                observedAt: request.observedAt
            )
        }

        if request.context.vmID != intent.vmID {
            return rejection(
                intent: intent,
                errorCode: .vmIdentityMismatch,
                observedAt: request.observedAt
            )
        }
        if !VMReclamationValidation.isCanonicalLifecyclePlanDigest(
            request.context.lifecyclePlanDigest
        ) || request.context.lifecyclePlanDigest != intent.lifecyclePlanDigest {
            return rejection(
                intent: intent,
                errorCode: .lifecyclePlanDigestMismatch,
                observedAt: request.observedAt
            )
        }
        if request.context.fencingToken != intent.fencingToken {
            return rejection(
                intent: intent,
                errorCode: .staleFence,
                observedAt: request.observedAt
            )
        }

        if request.memorySample != nil && request.transition != .memorySample {
            return rejection(
                intent: intent,
                errorCode: .invalidTransition,
                observedAt: request.observedAt
            )
        }

        if request.observedAt.timeIntervalSince1970.isFinite == false {
            return rejection(
                intent: intent,
                errorCode: .outOfOrderObservation,
                observedAt: request.observedAt
            )
        }

        if request.observedAt < intent.plannedAt {
            return rejection(
                intent: intent,
                errorCode: .outOfOrderObservation,
                observedAt: request.observedAt
            )
        }

        if let lastObservedAt = intent.lastObservedAt,
           request.observedAt <= lastObservedAt {
            return rejection(
                intent: intent,
                errorCode: .outOfOrderObservation,
                observedAt: request.observedAt
            )
        }

        if intent.state == .reclaimed || intent.state == .failed {
            return result(
                intent: intent,
                reasonCode: intent.state == .reclaimed ? .reclaimed : .failed,
                errorCode: .terminalState,
                observedAt: request.observedAt
            )
        }

        if request.observedAt > intent.expiresAt {
            return authoritativeFailure(
                intent: intent,
                errorCode: .expired,
                observedAt: request.observedAt
            )
        }

        switch request.transition {
        case .stopConfirmed:
            guard intent.state == .planned else {
                return transitionFailure(
                    intent: intent,
                    isDuplicate: intent.state == .stopConfirmed,
                    observedAt: request.observedAt
                )
            }
            return success(
                intent: nextIntent(
                    from: intent,
                    state: .stopConfirmed,
                    lastObservedAt: request.observedAt,
                    reasonCode: .stopConfirmed
                ),
                reasonCode: .stopConfirmed,
                observedAt: request.observedAt
            )

        case .removeConfirmed:
            guard intent.state == .stopConfirmed else {
                return transitionFailure(
                    intent: intent,
                    isDuplicate: intent.state == .removeConfirmed,
                    observedAt: request.observedAt
                )
            }
            return success(
                intent: nextIntent(
                    from: intent,
                    state: .removeConfirmed,
                    lastObservedAt: request.observedAt,
                    reasonCode: .removeConfirmed
                ),
                reasonCode: .removeConfirmed,
                observedAt: request.observedAt
            )

        case .beginVerification:
            guard intent.state == .removeConfirmed else {
                return transitionFailure(
                    intent: intent,
                    isDuplicate: intent.state == .verifying,
                    observedAt: request.observedAt
                )
            }
            return success(
                intent: nextIntent(
                    from: intent,
                    state: .verifying,
                    lastObservedAt: request.observedAt,
                    reasonCode: .verificationStarted
                ),
                reasonCode: .verificationStarted,
                observedAt: request.observedAt
            )

        case .memorySample:
            guard intent.state == .verifying || intent.state == .held else {
                return transitionFailure(
                    intent: intent,
                    isDuplicate: false,
                    observedAt: request.observedAt
                )
            }
            return applyMemorySample(to: intent, request: request)

        case .timeout:
            return authoritativeFailure(
                intent: intent,
                errorCode: .timedOut,
                observedAt: request.observedAt
            )
        }
    }

    private func applyMemorySample(
        to intent: VMReclamationIntent,
        request: VMReclamationTransitionRequest
    ) -> VMReclamationResult {
        guard let sample = request.memorySample else {
            return rejection(
                intent: intent,
                errorCode: .invalidSample,
                observedAt: request.observedAt
            )
        }

        guard sample.observedAt == request.observedAt else {
            return rejection(
                intent: intent,
                errorCode: .outOfOrderObservation,
                observedAt: request.observedAt
            )
        }

        guard sample.isValid,
              sample.totalBytes == intent.beforeSample.totalBytes else {
            return rejection(
                intent: intent,
                errorCode: .invalidSample,
                observedAt: request.observedAt
            )
        }

        guard sample.observedAt >= intent.plannedAt,
              sample.observedAt > intent.beforeSample.observedAt,
              sample.observedAt > (intent.lastObservedAt ?? intent.beforeSample.observedAt) else {
            return rejection(
                intent: intent,
                errorCode: .outOfOrderObservation,
                observedAt: request.observedAt
            )
        }

        if let previousSample = intent.lastMemorySample,
           sample.availableBytes < previousSample.availableBytes {
            return rejection(
                intent: intent,
                errorCode: .decreasingSample,
                observedAt: request.observedAt
            )
        }

        guard sample.availableBytes >= intent.beforeSample.availableBytes else {
            return rejection(
                intent: intent,
                errorCode: .decreasingSample,
                observedAt: request.observedAt
            )
        }

        let recoveredBytes = sample.availableBytes - intent.beforeSample.availableBytes
        guard recoveredBytes >= intent.requestedBytes else {
            let heldIntent = nextIntent(
                from: intent,
                state: .held,
                lastObservedAt: request.observedAt,
                lastMemorySample: sample,
                consecutiveStableSamples: 0,
                reasonCode: .recoveryBelowThreshold
            )
            return success(
                intent: heldIntent,
                reasonCode: .recoveryBelowThreshold,
                observedAt: request.observedAt
            )
        }

        let stableSamples = intent.consecutiveStableSamples + 1
        guard stableSamples >= configuration.stabilitySampleCount else {
            let heldIntent = nextIntent(
                from: intent,
                state: .held,
                lastObservedAt: request.observedAt,
                lastMemorySample: sample,
                consecutiveStableSamples: stableSamples,
                reasonCode: .stabilityWindowPending
            )
            return success(
                intent: heldIntent,
                reasonCode: .stabilityWindowPending,
                observedAt: request.observedAt
            )
        }

        let measuredBytes = min(recoveredBytes, intent.requestedBytes)
        let reclaimedIntent = nextIntent(
            from: intent,
            state: .reclaimed,
            lastObservedAt: request.observedAt,
            lastMemorySample: sample,
            consecutiveStableSamples: stableSamples,
            measuredReclaimedBytes: measuredBytes,
            reasonCode: .reclaimed
        )
        return success(
            intent: reclaimedIntent,
            reasonCode: .reclaimed,
            observedAt: request.observedAt
        )
    }

    private func nextIntent(
        from intent: VMReclamationIntent,
        state: VMReclamationTransitionState,
        lastObservedAt: Date? = nil,
        lastMemorySample: VMReclamationMemorySample? = nil,
        consecutiveStableSamples: Int? = nil,
        measuredReclaimedBytes: UInt64? = nil,
        reasonCode: VMReclamationReasonCode? = nil,
        errorCode: VMReclamationErrorCode? = nil
    ) -> VMReclamationIntent {
        VMReclamationIntent(
            vmID: intent.vmID,
            lifecyclePlanDigest: intent.lifecyclePlanDigest,
            fencingToken: intent.fencingToken,
            requestedBytes: intent.requestedBytes,
            beforeSample: intent.beforeSample,
            ownership: intent.ownership,
            configurationVersion: intent.configurationVersion,
            stabilitySampleCount: intent.stabilitySampleCount,
            plannedAt: intent.plannedAt,
            expiresAt: intent.expiresAt,
            state: state,
            lastObservedAt: lastObservedAt ?? intent.lastObservedAt,
            lastMemorySample: lastMemorySample ?? intent.lastMemorySample,
            consecutiveStableSamples: consecutiveStableSamples ?? intent.consecutiveStableSamples,
            measuredReclaimedBytes: measuredReclaimedBytes ?? intent.measuredReclaimedBytes,
            lastReasonCode: reasonCode ?? intent.lastReasonCode,
            lastErrorCode: errorCode
        )
    }

    private func success(
        intent: VMReclamationIntent,
        reasonCode: VMReclamationReasonCode,
        observedAt: Date
    ) -> VMReclamationResult {
        result(
            intent: intent,
            reasonCode: reasonCode,
            errorCode: nil,
            observedAt: observedAt
        )
    }

    private func rejection(
        intent: VMReclamationIntent,
        errorCode: VMReclamationErrorCode,
        observedAt: Date
    ) -> VMReclamationResult {
        return result(
            intent: intent,
            reasonCode: .failed,
            errorCode: errorCode,
            observedAt: observedAt
        )
    }

    private func authoritativeFailure(
        intent: VMReclamationIntent,
        errorCode: VMReclamationErrorCode,
        observedAt: Date
    ) -> VMReclamationResult {
        let failedIntent = nextIntent(
            from: intent,
            state: .failed,
            lastObservedAt: observedAt,
            measuredReclaimedBytes: 0,
            reasonCode: failureReason(for: errorCode),
            errorCode: errorCode
        )
        return result(
            intent: failedIntent,
            reasonCode: failureReason(for: errorCode),
            errorCode: errorCode,
            observedAt: observedAt
        )
    }

    private func transitionFailure(
        intent: VMReclamationIntent,
        isDuplicate: Bool,
        observedAt: Date
    ) -> VMReclamationResult {
        rejection(
            intent: intent,
            errorCode: isDuplicate ? .duplicateTransition : .outOfOrderTransition,
            observedAt: observedAt
        )
    }

    private func result(
        intent: VMReclamationIntent,
        reasonCode: VMReclamationReasonCode,
        errorCode: VMReclamationErrorCode?,
        observedAt: Date
    ) -> VMReclamationResult {
        VMReclamationResult(
            intent: intent,
            reasonCode: reasonCode,
            errorCode: errorCode,
            observedAt: observedAt
        )
    }

    private func failureReason(
        for errorCode: VMReclamationErrorCode
    ) -> VMReclamationReasonCode {
        switch errorCode {
        case .timedOut:
            return .timedOut
        case .expired:
            return .expired
        default:
            return .failed
        }
    }
}
