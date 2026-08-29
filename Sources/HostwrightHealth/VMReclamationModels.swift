import Foundation

public enum VMReclamationOwnership: String, Codable, CaseIterable, Equatable, Sendable {
    case hostwrightOwned = "hostwright-owned"
    case unmanaged
}

public enum VMReclamationTransitionState: String, Codable, CaseIterable, Equatable, Sendable {
    case planned
    case stopConfirmed = "stop-confirmed"
    case removeConfirmed = "remove-confirmed"
    case verifying
    case held
    case reclaimed
    case failed
}

public enum VMReclamationTransition: String, Codable, CaseIterable, Equatable, Sendable {
    case stopConfirmed = "stop-confirmed"
    case removeConfirmed = "remove-confirmed"
    case beginVerification = "begin-verification"
    case memorySample = "memory-sample"
    case timeout
}

public enum VMReclamationReasonCode: String, Codable, CaseIterable, Equatable, Sendable {
    case planned
    case stopConfirmed = "stop-confirmed"
    case removeConfirmed = "remove-confirmed"
    case verificationStarted = "verification-started"
    case recoveryBelowThreshold = "recovery-below-threshold"
    case stabilityWindowPending = "stability-window-pending"
    case held
    case reclaimed
    case failed
    case timedOut = "timed-out"
    case expired
}

public enum VMReclamationErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    case staleFence = "stale-fence"
    case vmIdentityMismatch = "vm-identity-mismatch"
    case lifecyclePlanDigestMismatch = "lifecycle-plan-digest-mismatch"
    case unmanagedOwnership = "unmanaged-ownership"
    case invalidSample = "invalid-sample"
    case decreasingSample = "decreasing-sample"
    case outOfOrderObservation = "out-of-order-observation"
    case duplicateTransition = "duplicate-transition"
    case outOfOrderTransition = "out-of-order-transition"
    case expired
    case timedOut = "timed-out"
    case invalidTransition = "invalid-transition"
    case configurationMismatch = "configuration-mismatch"
    case terminalState = "terminal-state"
}

public enum VMReclamationIntentError: String, Error, Codable, Equatable, Sendable {
    case invalidArgument = "invalid-argument"
}

public enum VMReclamationConfigurationError: String, Error, Codable, Equatable, Sendable {
    case unknownVersion = "unknown-version"
    case invalidStabilitySampleCount = "invalid-stability-sample-count"
}

internal enum VMReclamationValidation {
    static func isCanonicalLifecyclePlanDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            }
    }
}

public struct VMReclamationMemorySample: Codable, Equatable, Sendable {
    public let availableBytes: UInt64
    public let totalBytes: UInt64
    public let observedAt: Date

    public init(
        availableBytes: UInt64,
        totalBytes: UInt64,
        observedAt: Date
    ) {
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.observedAt = observedAt
    }

    internal var isValid: Bool {
        totalBytes > 0 &&
            availableBytes <= totalBytes &&
            observedAt.timeIntervalSince1970.isFinite
    }
}

public struct VMReclamationTransitionContext: Codable, Equatable, Sendable {
    public let vmID: UUID
    public let lifecyclePlanDigest: String
    public let fencingToken: UInt64

    public init(
        vmID: UUID,
        lifecyclePlanDigest: String,
        fencingToken: UInt64
    ) {
        self.vmID = vmID
        self.lifecyclePlanDigest = lifecyclePlanDigest
        self.fencingToken = fencingToken
    }
}

public struct VMReclamationTransitionRequest: Codable, Equatable, Sendable {
    public let transition: VMReclamationTransition
    public let context: VMReclamationTransitionContext
    public let observedAt: Date
    public let memorySample: VMReclamationMemorySample?

    public init(
        transition: VMReclamationTransition,
        context: VMReclamationTransitionContext,
        observedAt: Date,
        memorySample: VMReclamationMemorySample? = nil
    ) {
        self.transition = transition
        self.context = context
        self.observedAt = observedAt
        self.memorySample = memorySample
    }
}

public struct VMReclamationIntent: Codable, Equatable, Sendable {
    public let vmID: UUID
    public let lifecyclePlanDigest: String
    public let fencingToken: UInt64
    public let requestedBytes: UInt64
    public let beforeSample: VMReclamationMemorySample
    public let ownership: VMReclamationOwnership
    public let configurationVersion: Int
    public let stabilitySampleCount: Int
    public let plannedAt: Date
    public let expiresAt: Date
    public let state: VMReclamationTransitionState
    public let lastObservedAt: Date?
    public let lastMemorySample: VMReclamationMemorySample?
    public let consecutiveStableSamples: Int
    public let measuredReclaimedBytes: UInt64
    public let lastReasonCode: VMReclamationReasonCode?
    public let lastErrorCode: VMReclamationErrorCode?

    public init(
        vmID: UUID,
        lifecyclePlanDigest: String,
        fencingToken: UInt64,
        requestedBytes: UInt64,
        beforeSample: VMReclamationMemorySample,
        ownership: VMReclamationOwnership,
        plannedAt: Date,
        expiresAt: Date,
        configuration: VMReclamationConfiguration = .standard
    ) throws {
        guard VMReclamationValidation.isCanonicalLifecyclePlanDigest(
            lifecyclePlanDigest
        ),
              fencingToken > 0,
              requestedBytes > 0,
              beforeSample.isValid,
              beforeSample.observedAt <= plannedAt,
              plannedAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > plannedAt else {
            throw VMReclamationIntentError.invalidArgument
        }

        self.init(
            vmID: vmID,
            lifecyclePlanDigest: lifecyclePlanDigest,
            fencingToken: fencingToken,
            requestedBytes: requestedBytes,
            beforeSample: beforeSample,
            ownership: ownership,
            configurationVersion: configuration.version,
            stabilitySampleCount: configuration.stabilitySampleCount,
            plannedAt: plannedAt,
            expiresAt: expiresAt,
            state: .planned,
            lastObservedAt: nil,
            lastMemorySample: nil,
            consecutiveStableSamples: 0,
            measuredReclaimedBytes: 0,
            lastReasonCode: .planned,
            lastErrorCode: nil
        )
    }

    internal init(
        vmID: UUID,
        lifecyclePlanDigest: String,
        fencingToken: UInt64,
        requestedBytes: UInt64,
        beforeSample: VMReclamationMemorySample,
        ownership: VMReclamationOwnership,
        configurationVersion: Int,
        stabilitySampleCount: Int,
        plannedAt: Date,
        expiresAt: Date,
        state: VMReclamationTransitionState,
        lastObservedAt: Date?,
        lastMemorySample: VMReclamationMemorySample?,
        consecutiveStableSamples: Int,
        measuredReclaimedBytes: UInt64,
        lastReasonCode: VMReclamationReasonCode?,
        lastErrorCode: VMReclamationErrorCode?
    ) {
        self.vmID = vmID
        self.lifecyclePlanDigest = lifecyclePlanDigest
        self.fencingToken = fencingToken
        self.requestedBytes = requestedBytes
        self.beforeSample = beforeSample
        self.ownership = ownership
        self.configurationVersion = configurationVersion
        self.stabilitySampleCount = stabilitySampleCount
        self.plannedAt = plannedAt
        self.expiresAt = expiresAt
        self.state = state
        self.lastObservedAt = lastObservedAt
        self.lastMemorySample = lastMemorySample
        self.consecutiveStableSamples = consecutiveStableSamples
        self.measuredReclaimedBytes = measuredReclaimedBytes
        self.lastReasonCode = lastReasonCode
        self.lastErrorCode = lastErrorCode
    }

    private enum CodingKeys: String, CodingKey {
        case vmID
        case lifecyclePlanDigest
        case fencingToken
        case requestedBytes
        case beforeSample
        case ownership
        case configurationVersion
        case stabilitySampleCount
        case plannedAt
        case expiresAt
        case state
        case lastObservedAt
        case lastMemorySample
        case consecutiveStableSamples
        case measuredReclaimedBytes
        case lastReasonCode
        case lastErrorCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let vmID = try container.decode(UUID.self, forKey: .vmID)
        let lifecyclePlanDigest = try container.decode(
            String.self,
            forKey: .lifecyclePlanDigest
        )
        let fencingToken = try container.decode(UInt64.self, forKey: .fencingToken)
        let requestedBytes = try container.decode(UInt64.self, forKey: .requestedBytes)
        let beforeSample = try container.decode(
            VMReclamationMemorySample.self,
            forKey: .beforeSample
        )
        let ownership = try container.decode(
            VMReclamationOwnership.self,
            forKey: .ownership
        )
        let configurationVersion = try container.decode(
            Int.self,
            forKey: .configurationVersion
        )
        let stabilitySampleCount = try container.decode(
            Int.self,
            forKey: .stabilitySampleCount
        )
        let plannedAt = try container.decode(Date.self, forKey: .plannedAt)
        let expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        let state = try container.decode(
            VMReclamationTransitionState.self,
            forKey: .state
        )
        let lastObservedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastObservedAt
        )
        let lastMemorySample = try container.decodeIfPresent(
            VMReclamationMemorySample.self,
            forKey: .lastMemorySample
        )
        let consecutiveStableSamples = try container.decode(
            Int.self,
            forKey: .consecutiveStableSamples
        )
        let measuredReclaimedBytes = try container.decode(
            UInt64.self,
            forKey: .measuredReclaimedBytes
        )
        let lastReasonCode = try container.decodeIfPresent(
            VMReclamationReasonCode.self,
            forKey: .lastReasonCode
        )
        let lastErrorCode = try container.decodeIfPresent(
            VMReclamationErrorCode.self,
            forKey: .lastErrorCode
        )

        let configuration = try VMReclamationConfiguration(
            stabilitySampleCount: stabilitySampleCount,
            version: configurationVersion
        )
        try Self.validatePersistedState(
            lifecyclePlanDigest: lifecyclePlanDigest,
            fencingToken: fencingToken,
            requestedBytes: requestedBytes,
            beforeSample: beforeSample,
            configuration: configuration,
            plannedAt: plannedAt,
            expiresAt: expiresAt,
            state: state,
            lastObservedAt: lastObservedAt,
            lastMemorySample: lastMemorySample,
            consecutiveStableSamples: consecutiveStableSamples,
            measuredReclaimedBytes: measuredReclaimedBytes,
            lastReasonCode: lastReasonCode,
            lastErrorCode: lastErrorCode
        )

        self.init(
            vmID: vmID,
            lifecyclePlanDigest: lifecyclePlanDigest,
            fencingToken: fencingToken,
            requestedBytes: requestedBytes,
            beforeSample: beforeSample,
            ownership: ownership,
            configurationVersion: configuration.version,
            stabilitySampleCount: configuration.stabilitySampleCount,
            plannedAt: plannedAt,
            expiresAt: expiresAt,
            state: state,
            lastObservedAt: lastObservedAt,
            lastMemorySample: lastMemorySample,
            consecutiveStableSamples: consecutiveStableSamples,
            measuredReclaimedBytes: measuredReclaimedBytes,
            lastReasonCode: lastReasonCode,
            lastErrorCode: lastErrorCode
        )
    }

    private static func validatePersistedState(
        lifecyclePlanDigest: String,
        fencingToken: UInt64,
        requestedBytes: UInt64,
        beforeSample: VMReclamationMemorySample,
        configuration: VMReclamationConfiguration,
        plannedAt: Date,
        expiresAt: Date,
        state: VMReclamationTransitionState,
        lastObservedAt: Date?,
        lastMemorySample: VMReclamationMemorySample?,
        consecutiveStableSamples: Int,
        measuredReclaimedBytes: UInt64,
        lastReasonCode: VMReclamationReasonCode?,
        lastErrorCode: VMReclamationErrorCode?
    ) throws {
        guard VMReclamationValidation.isCanonicalLifecyclePlanDigest(
            lifecyclePlanDigest
        ),
              fencingToken > 0,
              requestedBytes > 0,
              beforeSample.isValid,
              beforeSample.observedAt <= plannedAt,
              plannedAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > plannedAt,
              (0...configuration.stabilitySampleCount).contains(consecutiveStableSamples),
              measuredReclaimedBytes <= requestedBytes else {
            throw VMReclamationIntentError.invalidArgument
        }

        if let lastObservedAt {
            guard lastObservedAt.timeIntervalSince1970.isFinite,
                  lastObservedAt >= plannedAt else {
                throw VMReclamationIntentError.invalidArgument
            }
        }
        if let lastMemorySample {
            guard lastMemorySample.isValid,
                  lastMemorySample.totalBytes == beforeSample.totalBytes,
                  lastMemorySample.observedAt >= plannedAt,
                  lastMemorySample.observedAt > beforeSample.observedAt,
                  lastMemorySample.availableBytes >= beforeSample.availableBytes,
                  lastMemorySample.observedAt <= expiresAt else {
                throw VMReclamationIntentError.invalidArgument
            }
        }

        switch state {
        case .failed:
            guard let lastObservedAt else {
                throw VMReclamationIntentError.invalidArgument
            }
            if let lastMemorySample {
                guard lastObservedAt >= lastMemorySample.observedAt else {
                    throw VMReclamationIntentError.invalidArgument
                }
            }
        default:
            if let lastObservedAt {
                guard lastObservedAt <= expiresAt else {
                    throw VMReclamationIntentError.invalidArgument
                }
            }
            if let lastMemorySample {
                guard lastObservedAt == lastMemorySample.observedAt else {
                    throw VMReclamationIntentError.invalidArgument
                }
            }
        }

        switch state {
        case .planned:
            guard lastObservedAt == nil,
                  lastMemorySample == nil,
                  consecutiveStableSamples == 0,
                  measuredReclaimedBytes == 0,
                  lastReasonCode == .planned,
                  lastErrorCode == nil else {
                throw VMReclamationIntentError.invalidArgument
            }
        case .stopConfirmed:
            guard lastObservedAt != nil,
                  lastMemorySample == nil,
                  consecutiveStableSamples == 0,
                  measuredReclaimedBytes == 0,
                  lastReasonCode == .stopConfirmed,
                  lastErrorCode == nil else {
                throw VMReclamationIntentError.invalidArgument
            }
        case .removeConfirmed:
            guard lastObservedAt != nil,
                  lastMemorySample == nil,
                  consecutiveStableSamples == 0,
                  measuredReclaimedBytes == 0,
                  lastReasonCode == .removeConfirmed,
                  lastErrorCode == nil else {
                throw VMReclamationIntentError.invalidArgument
            }
        case .verifying:
            guard lastObservedAt != nil,
                  lastMemorySample == nil,
                  consecutiveStableSamples == 0,
                  measuredReclaimedBytes == 0,
                  lastReasonCode == .verificationStarted,
                  lastErrorCode == nil else {
                throw VMReclamationIntentError.invalidArgument
            }
        case .held:
            guard let lastMemorySample,
                  lastObservedAt != nil,
                  measuredReclaimedBytes == 0,
                  lastErrorCode == nil else {
                throw VMReclamationIntentError.invalidArgument
            }
            let recoveredBytes = lastMemorySample.availableBytes
                - beforeSample.availableBytes
            switch lastReasonCode {
            case .recoveryBelowThreshold:
                guard recoveredBytes < requestedBytes,
                      consecutiveStableSamples == 0 else {
                    throw VMReclamationIntentError.invalidArgument
                }
            case .stabilityWindowPending:
                guard recoveredBytes >= requestedBytes,
                      consecutiveStableSamples < configuration.stabilitySampleCount else {
                    throw VMReclamationIntentError.invalidArgument
                }
            default:
                throw VMReclamationIntentError.invalidArgument
            }
        case .reclaimed:
            guard let lastMemorySample,
                  lastObservedAt != nil,
                  consecutiveStableSamples >= configuration.stabilitySampleCount,
                  measuredReclaimedBytes > 0,
                  lastReasonCode == .reclaimed,
                  lastErrorCode == nil else {
                throw VMReclamationIntentError.invalidArgument
            }
            let recoveredBytes = lastMemorySample.availableBytes
                - beforeSample.availableBytes
            guard recoveredBytes >= requestedBytes,
                  measuredReclaimedBytes <= min(recoveredBytes, requestedBytes) else {
                throw VMReclamationIntentError.invalidArgument
            }
        case .failed:
            guard measuredReclaimedBytes == 0,
                  lastReasonCode == .timedOut
                    || lastReasonCode == .expired,
                  lastErrorCode == .timedOut
                    || lastErrorCode == .expired,
                  lastObservedAt != nil else {
                throw VMReclamationIntentError.invalidArgument
            }
            if lastReasonCode == .timedOut {
                guard lastObservedAt! <= expiresAt else {
                    throw VMReclamationIntentError.invalidArgument
                }
            } else {
                guard lastObservedAt! > expiresAt else {
                    throw VMReclamationIntentError.invalidArgument
                }
            }
        }
    }
}

public struct VMReclamationConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumStabilitySampleCount = 1_024

    public let version: Int
    public let stabilitySampleCount: Int

    public init(
        stabilitySampleCount: Int = 2,
        version: Int = 1
    ) throws {
        guard version == Self.currentVersion else {
            throw VMReclamationConfigurationError.unknownVersion
        }
        guard (1...Self.maximumStabilitySampleCount).contains(
            stabilitySampleCount
        ) else {
            throw VMReclamationConfigurationError.invalidStabilitySampleCount
        }
        self.version = version
        self.stabilitySampleCount = stabilitySampleCount
    }

    public static let standard = try! VMReclamationConfiguration()

    private enum CodingKeys: String, CodingKey {
        case version
        case stabilitySampleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            stabilitySampleCount: container.decode(
                Int.self,
                forKey: .stabilitySampleCount
            ),
            version: container.decode(Int.self, forKey: .version)
        )
    }
}

public struct VMReclamationResult: Codable, Equatable, Sendable {
    public let intent: VMReclamationIntent
    public let state: VMReclamationTransitionState
    public let reasonCode: VMReclamationReasonCode
    public let errorCode: VMReclamationErrorCode?
    public let observedAt: Date
    public let measuredReclaimedBytes: UInt64

    internal init(
        intent: VMReclamationIntent,
        reasonCode: VMReclamationReasonCode,
        errorCode: VMReclamationErrorCode?,
        observedAt: Date
    ) {
        self.intent = intent
        self.state = intent.state
        self.reasonCode = reasonCode
        self.errorCode = errorCode
        self.observedAt = observedAt
        self.measuredReclaimedBytes = intent.measuredReclaimedBytes
    }
}
