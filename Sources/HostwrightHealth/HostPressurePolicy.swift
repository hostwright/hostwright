import Foundation

public enum HostPressurePolicyConfigurationError: String, Error, Codable, Equatable, Sendable {
    case unknownVersion = "unknown-version"
    case invalidRecoveryObservationCount = "invalid-recovery-observation-count"
    case invalidBatteryThreshold = "invalid-battery-threshold"
}

public struct HostPressurePolicyConfiguration: Codable, Equatable, Sendable {
    public let recoveryObservationCount: Int
    public let batteryDeweightBelowPercent: Double
    public let version: Int

    public static let currentVersion = 1
    public static let maximumRecoveryObservationCount = 1_024

    public init(
        recoveryObservationCount: Int = 2,
        batteryDeweightBelowPercent: Double = 20,
        version: Int = 1
    ) throws {
        guard version == Self.currentVersion else {
            throw HostPressurePolicyConfigurationError.unknownVersion
        }
        guard (1...Self.maximumRecoveryObservationCount).contains(
            recoveryObservationCount
        ) else {
            throw HostPressurePolicyConfigurationError.invalidRecoveryObservationCount
        }
        guard batteryDeweightBelowPercent.isFinite,
              (0...100).contains(batteryDeweightBelowPercent) else {
            throw HostPressurePolicyConfigurationError.invalidBatteryThreshold
        }
        self.recoveryObservationCount = recoveryObservationCount
        self.batteryDeweightBelowPercent = batteryDeweightBelowPercent
        self.version = version
    }

    public static let standard = try! HostPressurePolicyConfiguration()

    private enum CodingKeys: String, CodingKey {
        case recoveryObservationCount
        case batteryDeweightBelowPercent
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recoveryObservationCount: container.decode(
                Int.self,
                forKey: .recoveryObservationCount
            ),
            batteryDeweightBelowPercent: container.decode(
                Double.self,
                forKey: .batteryDeweightBelowPercent
            ),
            version: container.decode(Int.self, forKey: .version)
        )
    }
}

public enum HostPressureReasonCode: String, Codable, CaseIterable, Equatable, Sendable {
    case allowed
    case hysteresisRecovery = "hysteresis-recovery"
    case hysteresisVersionMismatch = "hysteresis-version-mismatch"
    case hysteresisStateInvalid = "hysteresis-state-invalid"

    case lowPowerMode = "low-power-mode"
    case batteryPowerSource = "battery-power-source"
    case batteryLow = "battery-low"
    case diskWarning = "disk-warning"
    case diskFair = "disk-fair"
    case diskSerious = "disk-serious"
    case thermalWarning = "thermal-warning"
    case thermalFair = "thermal-fair"
    case thermalSerious = "thermal-serious"
    case memoryWarning = "memory-warning"
    case memoryFair = "memory-fair"
    case memorySerious = "memory-serious"

    case hostUnavailable = "host-unavailable"
    case thermalCritical = "thermal-critical"
    case thermalUnavailable = "thermal-unavailable"
    case memoryCritical = "memory-critical"
    case memoryUnavailable = "memory-unavailable"
    case sleeping
    case sleepUnavailable = "sleep-unavailable"
    case maintenance
    case maintenanceUnavailable = "maintenance-unavailable"
    case diskCritical = "disk-critical"
    case diskUnavailable = "disk-unavailable"
    case powerSourceUnavailable = "power-source-unavailable"
    case batteryLevelUnavailable = "battery-level-unavailable"
}

private extension HostPressureReasonCode {
    var deterministicRank: Int {
        switch self {
        case .hysteresisVersionMismatch:
            return 0
        case .hysteresisStateInvalid:
            return 1
        case .hysteresisRecovery:
            return 2
        case .allowed:
            return 3
        case .hostUnavailable:
            return 10
        case .thermalWarning:
            return 20
        case .thermalFair:
            return 21
        case .thermalSerious:
            return 22
        case .thermalCritical:
            return 23
        case .thermalUnavailable:
            return 24
        case .memoryWarning:
            return 30
        case .memoryFair:
            return 31
        case .memorySerious:
            return 32
        case .memoryCritical:
            return 33
        case .memoryUnavailable:
            return 34
        case .sleeping:
            return 40
        case .sleepUnavailable:
            return 41
        case .maintenance:
            return 42
        case .maintenanceUnavailable:
            return 43
        case .diskWarning:
            return 50
        case .diskFair:
            return 51
        case .diskSerious:
            return 52
        case .diskCritical:
            return 53
        case .diskUnavailable:
            return 54
        case .lowPowerMode:
            return 60
        case .batteryPowerSource:
            return 61
        case .batteryLow:
            return 62
        case .powerSourceUnavailable:
            return 63
        case .batteryLevelUnavailable:
            return 64
        }
    }

    var isDeweightingReason: Bool {
        switch self {
        case .lowPowerMode,
             .batteryPowerSource,
             .batteryLow,
             .diskWarning,
             .diskFair,
             .diskSerious,
             .thermalWarning,
             .thermalFair,
             .thermalSerious,
             .memoryWarning,
             .memoryFair,
             .memorySerious:
            return true
        default:
            return false
        }
    }

    var isBlockingReason: Bool {
        switch self {
        case .hostUnavailable,
             .thermalCritical,
             .thermalUnavailable,
             .memoryCritical,
             .memoryUnavailable,
             .sleeping,
             .sleepUnavailable,
             .maintenance,
             .maintenanceUnavailable,
             .diskCritical,
             .diskUnavailable,
             .powerSourceUnavailable,
             .batteryLevelUnavailable:
            return true
        default:
            return false
        }
    }
}

public struct HostPressurePolicyDecision: Codable, Equatable, Sendable {
    public let version: Int
    public let posture: HostAdmissionPosture
    public let reasonCodes: [HostPressureReasonCode]
    public let observedAt: Date
    public let nextState: HostPressureHysteresisState

    public init(
        posture: HostAdmissionPosture,
        reasonCodes: [HostPressureReasonCode],
        observedAt: Date,
        nextState: HostPressureHysteresisState
    ) {
        self.version = nextState.version
        self.posture = posture
        self.reasonCodes = reasonCodes
        self.observedAt = observedAt
        self.nextState = nextState
    }

    public var reasonCode: HostPressureReasonCode {
        reasonCodes.first ?? .allowed
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case posture
        case reasonCodes
        case observedAt
        case nextState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let posture = try container.decode(
            HostAdmissionPosture.self,
            forKey: .posture
        )
        let reasonCodes = try container.decode(
            [HostPressureReasonCode].self,
            forKey: .reasonCodes
        )
        let nextState = try container.decode(
            HostPressureHysteresisState.self,
            forKey: .nextState
        )
        let version = try container.decode(Int.self, forKey: .version)
        let observedAt = try container.decode(Date.self, forKey: .observedAt)
        guard version == HostPressurePolicyConfiguration.currentVersion,
              version == nextState.version else {
            throw HostPressurePolicyConfigurationError.unknownVersion
        }
        guard posture == nextState.posture,
              Self.hasDeterministicReasons(reasonCodes, for: posture),
              observedAt.timeIntervalSince1970.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .posture,
                in: container,
                debugDescription: "Policy decision posture, reasons, and observation are inconsistent."
            )
        }
        self.init(
            posture: posture,
            reasonCodes: reasonCodes,
            observedAt: observedAt,
            nextState: nextState
        )
    }

    private static func hasDeterministicReasons(
        _ reasonCodes: [HostPressureReasonCode],
        for posture: HostAdmissionPosture
    ) -> Bool {
        guard !reasonCodes.isEmpty,
              reasonCodes == reasonCodes.sorted(by: {
                  $0.deterministicRank < $1.deterministicRank
              }) else {
            return false
        }

        for index in reasonCodes.indices.dropFirst() {
            guard reasonCodes[index] != reasonCodes[index - 1] else {
                return false
            }
        }

        switch posture {
        case .allowed:
            return reasonCodes == [.allowed]
        case .deweighted:
            return reasonCodes == [.hysteresisRecovery]
                || reasonCodes.allSatisfy(\.isDeweightingReason)
        case .blocked:
            if reasonCodes == [.hysteresisRecovery]
                || reasonCodes == [.hysteresisVersionMismatch]
                || reasonCodes == [.hysteresisStateInvalid] {
                return true
            }
            return reasonCodes.allSatisfy(\.isBlockingReason)
        }
    }

}

public struct HostPressurePolicy: Sendable {
    public let configuration: HostPressurePolicyConfiguration

    public init(
        configuration: HostPressurePolicyConfiguration = .standard
    ) {
        self.configuration = configuration
    }

    public func evaluate(
        sample: HostPressureSample,
        previousState: HostPressureHysteresisState = .initial
    ) -> HostPressurePolicyDecision {
        guard previousState.version == configuration.version else {
            return decision(
                posture: .blocked,
                reasons: [.hysteresisVersionMismatch],
                sample: sample,
                nextState: try! HostPressureHysteresisState(
                    previousPosture: .blocked,
                    version: configuration.version
                )
            )
        }
        guard previousState.consecutiveClearObservations
            <= configuration.recoveryObservationCount else {
            return decision(
                posture: .blocked,
                reasons: [.hysteresisStateInvalid],
                sample: sample,
                nextState: try! HostPressureHysteresisState(
                    previousPosture: .blocked,
                    version: configuration.version
                )
            )
        }

        var blockingReasons: [HostPressureReasonCode] = []
        var deweightingReasons: [HostPressureReasonCode] = []

        if sample.availability != .available {
            blockingReasons.append(.hostUnavailable)
        }

        evaluateThermal(
            sample.thermalState,
            blockingReasons: &blockingReasons,
            deweightingReasons: &deweightingReasons
        )
        evaluateMemory(
            sample.systemMemoryPressure,
            blockingReasons: &blockingReasons,
            deweightingReasons: &deweightingReasons
        )
        evaluateSleep(
            sample.sleepWakeState,
            blockingReasons: &blockingReasons
        )
        evaluateMaintenance(
            sample.maintenanceState,
            blockingReasons: &blockingReasons
        )
        evaluateDisk(
            sample.diskPressure.level,
            blockingReasons: &blockingReasons,
            deweightingReasons: &deweightingReasons
        )
        evaluatePower(
            sample,
            blockingReasons: &blockingReasons,
            deweightingReasons: &deweightingReasons
        )

        let rawPosture: HostAdmissionPosture
        let rawReasons: [HostPressureReasonCode]
        if !blockingReasons.isEmpty {
            rawPosture = .blocked
            rawReasons = blockingReasons
        } else if !deweightingReasons.isEmpty {
            rawPosture = .deweighted
            rawReasons = deweightingReasons
        } else {
            rawPosture = .allowed
            rawReasons = [.allowed]
        }

        return applyHysteresis(
            rawPosture: rawPosture,
            rawReasons: rawReasons,
            sample: sample,
            previousState: previousState
        )
    }

    private func evaluateThermal(
        _ level: HostPressureLevel,
        blockingReasons: inout [HostPressureReasonCode],
        deweightingReasons: inout [HostPressureReasonCode]
    ) {
        switch level {
        case .nominal:
            break
        case .warning:
            deweightingReasons.append(.thermalWarning)
        case .fair:
            deweightingReasons.append(.thermalFair)
        case .serious:
            deweightingReasons.append(.thermalSerious)
        case .critical:
            blockingReasons.append(.thermalCritical)
        case .unknown:
            blockingReasons.append(.thermalUnavailable)
        }
    }

    private func evaluateMemory(
        _ level: HostPressureLevel,
        blockingReasons: inout [HostPressureReasonCode],
        deweightingReasons: inout [HostPressureReasonCode]
    ) {
        switch level {
        case .nominal:
            break
        case .warning:
            deweightingReasons.append(.memoryWarning)
        case .fair:
            deweightingReasons.append(.memoryFair)
        case .serious:
            deweightingReasons.append(.memorySerious)
        case .critical:
            blockingReasons.append(.memoryCritical)
        case .unknown:
            blockingReasons.append(.memoryUnavailable)
        }
    }

    private func evaluateSleep(
        _ state: HostSleepWakeState,
        blockingReasons: inout [HostPressureReasonCode]
    ) {
        switch state {
        case .awake:
            break
        case .sleeping:
            blockingReasons.append(.sleeping)
        case .unknown:
            blockingReasons.append(.sleepUnavailable)
        }
    }

    private func evaluateMaintenance(
        _ state: HostMaintenanceState,
        blockingReasons: inout [HostPressureReasonCode]
    ) {
        switch state {
        case .inactive:
            break
        case .active:
            blockingReasons.append(.maintenance)
        case .unknown:
            blockingReasons.append(.maintenanceUnavailable)
        }
    }

    private func evaluateDisk(
        _ level: HostPressureLevel,
        blockingReasons: inout [HostPressureReasonCode],
        deweightingReasons: inout [HostPressureReasonCode]
    ) {
        switch level {
        case .nominal:
            break
        case .warning:
            deweightingReasons.append(.diskWarning)
        case .fair:
            deweightingReasons.append(.diskFair)
        case .serious:
            deweightingReasons.append(.diskSerious)
        case .critical:
            blockingReasons.append(.diskCritical)
        case .unknown:
            blockingReasons.append(.diskUnavailable)
        }
    }

    private func evaluatePower(
        _ sample: HostPressureSample,
        blockingReasons: inout [HostPressureReasonCode],
        deweightingReasons: inout [HostPressureReasonCode]
    ) {
        if sample.isLowPowerModeEnabled {
            deweightingReasons.append(.lowPowerMode)
        }

        let powerSourceSnapshot = HostPowerSourceSnapshot(
            availability: sample.powerSourceAvailability,
            battery: sample.battery
        )
        guard powerSourceSnapshot.isConsistent else {
            blockingReasons.append(.powerSourceUnavailable)
            return
        }
        if sample.powerSourceAvailability == .unavailable {
            blockingReasons.append(.powerSourceUnavailable)
            return
        }

        guard let battery = sample.battery else { return }
        switch battery.powerSource {
        case .ac:
            break
        case .battery, .ups:
            deweightingReasons.append(.batteryPowerSource)
        case .unknown, .unavailable:
            blockingReasons.append(.powerSourceUnavailable)
        }

        if let chargePercent = battery.chargePercent {
            guard chargePercent.isFinite, (0...100).contains(chargePercent) else {
                blockingReasons.append(.batteryLevelUnavailable)
                return
            }
            if chargePercent <= configuration.batteryDeweightBelowPercent {
                deweightingReasons.append(.batteryLow)
            }
        } else if battery.powerSource == .battery || battery.powerSource == .ups {
            blockingReasons.append(.batteryLevelUnavailable)
        }
    }

    private func applyHysteresis(
        rawPosture: HostAdmissionPosture,
        rawReasons: [HostPressureReasonCode],
        sample: HostPressureSample,
        previousState: HostPressureHysteresisState
    ) -> HostPressurePolicyDecision {
        switch rawPosture {
        case .blocked:
            return decision(
                posture: .blocked,
                reasons: rawReasons,
                sample: sample,
                nextState: try! HostPressureHysteresisState(
                    previousPosture: .blocked,
                    version: configuration.version
                )
            )
        case .deweighted:
            if previousState.posture == .blocked {
                let nextCount = previousState.consecutiveClearObservations + 1
                guard nextCount >= configuration.recoveryObservationCount else {
                    return decision(
                        posture: .blocked,
                        reasons: [.hysteresisRecovery],
                        sample: sample,
                        nextState: try! HostPressureHysteresisState(
                            previousPosture: .blocked,
                            consecutiveClearObservations: nextCount,
                            version: configuration.version
                        )
                    )
                }
            }
            return decision(
                posture: .deweighted,
                reasons: rawReasons,
                sample: sample,
                nextState: try! HostPressureHysteresisState(
                    previousPosture: .deweighted,
                    version: configuration.version
                )
            )
        case .allowed:
            guard previousState.posture != .allowed else {
                return decision(
                    posture: .allowed,
                    reasons: [.allowed],
                    sample: sample,
                    nextState: try! HostPressureHysteresisState(
                        version: configuration.version
                    )
                )
            }

            let nextCount = previousState.consecutiveClearObservations + 1
            guard nextCount >= configuration.recoveryObservationCount else {
                return decision(
                    posture: previousState.posture,
                    reasons: [.hysteresisRecovery],
                    sample: sample,
                    nextState: try! HostPressureHysteresisState(
                        previousPosture: previousState.posture,
                        consecutiveClearObservations: nextCount,
                        version: configuration.version
                    )
                )
            }
            return decision(
                posture: .allowed,
                reasons: [.allowed],
                sample: sample,
                nextState: try! HostPressureHysteresisState(
                    version: configuration.version
                )
            )
        }
    }

    private func decision(
        posture: HostAdmissionPosture,
        reasons: [HostPressureReasonCode],
        sample: HostPressureSample,
        nextState: HostPressureHysteresisState
    ) -> HostPressurePolicyDecision {
        HostPressurePolicyDecision(
            posture: posture,
            reasonCodes: reasons,
            observedAt: sample.observedAt,
            nextState: nextState
        )
    }
}
