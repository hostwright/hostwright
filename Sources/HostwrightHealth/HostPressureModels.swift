import Foundation

public enum HostPressureLevel: String, Codable, CaseIterable, Comparable, Equatable, Sendable {
    case nominal
    case warning
    case fair
    case serious
    case critical
    case unknown

    private var rank: Int {
        switch self {
        case .nominal:
            return 0
        case .warning:
            return 1
        case .fair:
            return 2
        case .serious:
            return 3
        case .critical:
            return 4
        case .unknown:
            return 5
        }
    }

    public static func < (lhs: HostPressureLevel, rhs: HostPressureLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public extension HostPressureLevel {
    init(processInfoThermalState: ProcessInfo.ThermalState) {
        switch processInfoThermalState {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .unknown
        }
    }
}

public enum HostPowerSource: String, Codable, CaseIterable, Equatable, Sendable {
    case ac
    case battery
    case ups
    case unknown
    case unavailable
}

public enum HostPowerSourceAvailability: String, Codable, CaseIterable, Equatable, Sendable {
    case available
    case noBattery = "no-battery"
    case unavailable
}

public struct HostBatterySnapshot: Codable, Equatable, Sendable {
    public let chargePercent: Double?
    public let powerSource: HostPowerSource
    public let isCharging: Bool?

    public init(
        chargePercent: Double? = nil,
        powerSource: HostPowerSource,
        isCharging: Bool? = nil
    ) {
        self.chargePercent = chargePercent
        self.powerSource = powerSource
        self.isCharging = isCharging
    }
}

public struct HostProcessInfoSnapshot: Codable, Equatable, Sendable {
    public let thermalState: HostPressureLevel
    public let isLowPowerModeEnabled: Bool

    public init(
        thermalState: HostPressureLevel,
        isLowPowerModeEnabled: Bool
    ) {
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

public struct HostDiskFacts: Codable, Equatable, Sendable {
    public let availableBytes: UInt64
    public let totalBytes: UInt64

    public init(
        availableBytes: UInt64,
        totalBytes: UInt64
    ) {
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }
}

public struct HostPowerSourceSnapshot: Codable, Equatable, Sendable {
    public let availability: HostPowerSourceAvailability
    public let battery: HostBatterySnapshot?

    public init(
        availability: HostPowerSourceAvailability,
        battery: HostBatterySnapshot? = nil
    ) {
        self.availability = availability
        self.battery = battery
    }

    public var isConsistent: Bool {
        switch availability {
        case .available:
            return battery != nil
        case .noBattery, .unavailable:
            return battery == nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case availability
        case battery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let availability = try container.decode(
            HostPowerSourceAvailability.self,
            forKey: .availability
        )
        let battery = try container.decodeIfPresent(
            HostBatterySnapshot.self,
            forKey: .battery
        )
        let snapshot = HostPowerSourceSnapshot(
            availability: availability,
            battery: battery
        )
        guard snapshot.isConsistent else {
            throw DecodingError.dataCorruptedError(
                forKey: .availability,
                in: container,
                debugDescription: "Power-source availability and battery facts are inconsistent."
            )
        }
        self = snapshot
    }
}

public enum HostSleepWakeState: String, Codable, CaseIterable, Equatable, Sendable {
    case awake
    case sleeping
    case unknown
}

public enum HostMaintenanceState: String, Codable, CaseIterable, Equatable, Sendable {
    case inactive
    case active
    case unknown
}

public enum HostAvailability: String, Codable, CaseIterable, Equatable, Sendable {
    case available
    case unavailable
    case unknown
}

public struct HostDiskPressureSnapshot: Codable, Equatable, Sendable {
    public let level: HostPressureLevel
    public let availableBytes: UInt64?
    public let totalBytes: UInt64?

    public init(
        level: HostPressureLevel,
        availableBytes: UInt64? = nil,
        totalBytes: UInt64? = nil
    ) {
        self.level = level
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }

    public static let nominal = HostDiskPressureSnapshot(level: .nominal)

    public var availablePercent: Double? {
        guard let availableBytes,
              let totalBytes,
              totalBytes > 0,
              availableBytes <= totalBytes else {
            return nil
        }
        return Double(availableBytes) / Double(totalBytes) * 100
    }
}

public struct HostPressureSample: Codable, Equatable, Sendable {
    public let thermalState: HostPressureLevel
    public let isLowPowerModeEnabled: Bool
    public let battery: HostBatterySnapshot?
    public let powerSourceAvailability: HostPowerSourceAvailability
    public let systemMemoryPressure: HostPressureLevel
    public let sleepWakeState: HostSleepWakeState
    public let diskPressure: HostDiskPressureSnapshot
    public let maintenanceState: HostMaintenanceState
    public let availability: HostAvailability
    public let observedAt: Date

    public init(
        thermalState: HostPressureLevel = .nominal,
        isLowPowerModeEnabled: Bool = false,
        battery: HostBatterySnapshot? = nil,
        powerSourceAvailability: HostPowerSourceAvailability? = nil,
        systemMemoryPressure: HostPressureLevel = .nominal,
        sleepWakeState: HostSleepWakeState = .awake,
        diskPressure: HostDiskPressureSnapshot = .nominal,
        maintenanceState: HostMaintenanceState = .inactive,
        availability: HostAvailability = .available,
        observedAt: Date
    ) {
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.battery = battery
        self.powerSourceAvailability = powerSourceAvailability
            ?? (battery == nil ? .noBattery : .available)
        self.systemMemoryPressure = systemMemoryPressure
        self.sleepWakeState = sleepWakeState
        self.diskPressure = diskPressure
        self.maintenanceState = maintenanceState
        self.availability = availability
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case thermalState
        case isLowPowerModeEnabled
        case battery
        case powerSourceAvailability
        case systemMemoryPressure
        case sleepWakeState
        case diskPressure
        case maintenanceState
        case availability
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let battery = try container.decodeIfPresent(
            HostBatterySnapshot.self,
            forKey: .battery
        )
        let explicitPowerSourceAvailability = try container.decodeIfPresent(
            HostPowerSourceAvailability.self,
            forKey: .powerSourceAvailability
        )
        let powerSourceSnapshot = HostPowerSourceSnapshot(
            availability: explicitPowerSourceAvailability
                ?? (battery == nil ? .noBattery : .available),
            battery: battery
        )
        guard powerSourceSnapshot.isConsistent else {
            throw DecodingError.dataCorruptedError(
                forKey: .powerSourceAvailability,
                in: container,
                debugDescription: "Power-source availability and battery facts are inconsistent."
            )
        }
        self.init(
            thermalState: try container.decode(HostPressureLevel.self, forKey: .thermalState),
            isLowPowerModeEnabled: try container.decode(Bool.self, forKey: .isLowPowerModeEnabled),
            battery: battery,
            powerSourceAvailability: powerSourceSnapshot.availability,
            systemMemoryPressure: try container.decode(HostPressureLevel.self, forKey: .systemMemoryPressure),
            sleepWakeState: try container.decode(HostSleepWakeState.self, forKey: .sleepWakeState),
            diskPressure: try container.decode(HostDiskPressureSnapshot.self, forKey: .diskPressure),
            maintenanceState: try container.decode(HostMaintenanceState.self, forKey: .maintenanceState),
            availability: try container.decode(HostAvailability.self, forKey: .availability),
            observedAt: try container.decode(Date.self, forKey: .observedAt)
        )
    }
}

public enum HostAdmissionPosture: String, Codable, CaseIterable, Equatable, Sendable {
    case allowed
    case deweighted
    case blocked
}

public enum HostPressureHysteresisStateError: String, Error, Codable, Equatable, Sendable {
    case invalidVersion = "invalid-version"
    case invalidObservationCount = "invalid-observation-count"
}

public struct HostPressureHysteresisState: Codable, Equatable, Sendable {
    public static let maximumObservationCount = 1_024

    public let version: Int
    public let posture: HostAdmissionPosture
    public let consecutiveClearObservations: Int

    public init(
        previousPosture: HostAdmissionPosture = .allowed,
        consecutiveClearObservations: Int = 0,
        version: Int = 1
    ) throws {
        guard version > 0 else {
            throw HostPressureHysteresisStateError.invalidVersion
        }
        guard (0...Self.maximumObservationCount).contains(consecutiveClearObservations) else {
            throw HostPressureHysteresisStateError.invalidObservationCount
        }
        self.version = version
        self.posture = previousPosture
        self.consecutiveClearObservations = consecutiveClearObservations
    }

    public static let initial = try! HostPressureHysteresisState()

    private enum CodingKeys: String, CodingKey {
        case version
        case posture
        case consecutiveClearObservations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            previousPosture: try container.decode(
                HostAdmissionPosture.self,
                forKey: .posture
            ),
            consecutiveClearObservations: try container.decode(
                Int.self,
                forKey: .consecutiveClearObservations
            ),
            version: try container.decode(Int.self, forKey: .version)
        )
    }
}
