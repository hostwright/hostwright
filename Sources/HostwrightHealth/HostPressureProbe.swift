import Dispatch
import Foundation
import IOKit.ps

/// Reads one immutable host-pressure observation using a caller-supplied time.
public protocol HostPressureProbe: Sendable {
    func sample(at observationTime: Date) -> HostPressureSample
}

public protocol HostProcessInfoReader: Sendable {
    func read() -> HostProcessInfoSnapshot
}

public protocol HostDiskFactsReader: Sendable {
    func read(for volumeURL: URL) -> HostDiskFacts?
}

public protocol HostPowerSourceReader: Sendable {
    func read() -> HostPowerSourceSnapshot
}

public struct MacOSProcessInfoReader: HostProcessInfoReader, Sendable {
    public init() {}

    public func read() -> HostProcessInfoSnapshot {
        let processInfo = ProcessInfo.processInfo
        return HostProcessInfoSnapshot(
            thermalState: HostPressureLevel(
                processInfoThermalState: processInfo.thermalState
            ),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
    }
}

public struct MacOSDiskFactsReader: HostDiskFactsReader, Sendable {
    public init() {}

    public func read(for volumeURL: URL) -> HostDiskFacts? {
        let attributes = try? FileManager().attributesOfFileSystem(
            forPath: volumeURL.path
        )
        guard let attributes,
              let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value,
              let total = (attributes[.systemSize] as? NSNumber)?.uint64Value else {
            return nil
        }
        return HostDiskFacts(
            availableBytes: available,
            totalBytes: total
        )
    }
}

public struct MacOSPowerSourceReader: HostPowerSourceReader, Sendable {
    public init() {}

    public func read() -> HostPowerSourceSnapshot {
        guard let powerSources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(powerSources)?.takeRetainedValue()
                as? [CFTypeRef] else {
            return HostPowerSourceSnapshot(availability: .unavailable)
        }

        guard !sources.isEmpty else {
            return HostPowerSourceSnapshot(availability: .noBattery)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(
                powerSources,
                source
            )?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let powerSource = Self.powerSource(
                from: description[kIOPSPowerSourceStateKey] as? String
            )
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let chargePercent: Double?
            if let current,
               let maximum,
               maximum > 0,
               current.isFinite,
               maximum.isFinite {
                chargePercent = min(max(current / maximum * 100, 0), 100)
            } else {
                chargePercent = nil
            }
            let isCharging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue

            return HostPowerSourceSnapshot(
                availability: .available,
                battery: HostBatterySnapshot(
                    chargePercent: chargePercent,
                    powerSource: powerSource,
                    isCharging: isCharging
                )
            )
        }

        return HostPowerSourceSnapshot(availability: .unavailable)
    }

    private static func powerSource(from value: String?) -> HostPowerSource {
        switch value {
        case kIOPSACPowerValue:
            return .ac
        case kIOPSBatteryPowerValue:
            return .battery
        case kIOPMUPSPowerKey:
            return .ups
        default:
            return .unknown
        }
    }
}

public enum HostDiskPressureThresholdsError: String, Error, Codable, Equatable, Sendable {
    case invalidWarningThreshold = "invalid-warning-threshold"
    case invalidCriticalThreshold = "invalid-critical-threshold"
    case criticalThresholdExceedsWarning = "critical-threshold-exceeds-warning"
}

public struct HostDiskPressureThresholds: Codable, Equatable, Sendable {
    public let warningAvailablePercent: Double
    public let criticalAvailablePercent: Double

    public init(
        warningAvailablePercent: Double = 20,
        criticalAvailablePercent: Double = 10
    ) throws {
        guard warningAvailablePercent.isFinite,
              (0...100).contains(warningAvailablePercent) else {
            throw HostDiskPressureThresholdsError.invalidWarningThreshold
        }
        guard criticalAvailablePercent.isFinite,
              (0...100).contains(criticalAvailablePercent) else {
            throw HostDiskPressureThresholdsError.invalidCriticalThreshold
        }
        guard criticalAvailablePercent <= warningAvailablePercent else {
            throw HostDiskPressureThresholdsError.criticalThresholdExceedsWarning
        }
        self.warningAvailablePercent = warningAvailablePercent
        self.criticalAvailablePercent = criticalAvailablePercent
    }

    public static let standard = try! HostDiskPressureThresholds()

    private enum CodingKeys: String, CodingKey {
        case warningAvailablePercent
        case criticalAvailablePercent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            warningAvailablePercent: container.decode(
                Double.self,
                forKey: .warningAvailablePercent
            ),
            criticalAvailablePercent: container.decode(
                Double.self,
                forKey: .criticalAvailablePercent
            )
        )
    }
}

/// Reads the synchronous macOS host facts available through public APIs.
///
/// Memory-pressure transitions are delivered by a caller-owned Dispatch source;
/// sleep, maintenance, and availability are likewise explicit inputs so this
/// value never hides mutable observer state or owns a clock.
public struct MacOSHostPressureProbe: HostPressureProbe, Sendable {
    public let volumeURL: URL
    public let systemMemoryPressure: HostPressureLevel
    public let sleepWakeState: HostSleepWakeState
    public let maintenanceState: HostMaintenanceState
    public let availability: HostAvailability
    public let diskPressureThresholds: HostDiskPressureThresholds
    public let processInfoReader: any HostProcessInfoReader
    public let diskFactsReader: any HostDiskFactsReader
    public let powerSourceReader: any HostPowerSourceReader

    public init(
        volumeURL: URL = URL(fileURLWithPath: "/"),
        systemMemoryPressure: HostPressureLevel = .unknown,
        memoryPressureEvent: DispatchSource.MemoryPressureEvent? = nil,
        sleepWakeState: HostSleepWakeState = .awake,
        maintenanceState: HostMaintenanceState = .inactive,
        availability: HostAvailability = .available,
        diskPressureThresholds: HostDiskPressureThresholds = .standard,
        processInfoReader: any HostProcessInfoReader = MacOSProcessInfoReader(),
        diskFactsReader: any HostDiskFactsReader = MacOSDiskFactsReader(),
        powerSourceReader: any HostPowerSourceReader = MacOSPowerSourceReader()
    ) {
        self.volumeURL = volumeURL
        self.systemMemoryPressure = memoryPressureEvent.map(Self.memoryPressureLevel(for:))
            ?? systemMemoryPressure
        self.sleepWakeState = sleepWakeState
        self.maintenanceState = maintenanceState
        self.availability = availability
        self.diskPressureThresholds = diskPressureThresholds
        self.processInfoReader = processInfoReader
        self.diskFactsReader = diskFactsReader
        self.powerSourceReader = powerSourceReader
    }

    public func sample(at observationTime: Date) -> HostPressureSample {
        let processInfo = processInfoReader.read()
        let powerSource = powerSourceReader.read()
        return HostPressureSample(
            thermalState: processInfo.thermalState,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            battery: powerSource.battery,
            powerSourceAvailability: powerSource.availability,
            systemMemoryPressure: systemMemoryPressure,
            sleepWakeState: sleepWakeState,
            diskPressure: diskPressureSnapshot(),
            maintenanceState: maintenanceState,
            availability: availability,
            observedAt: observationTime
        )
    }

    public static func memoryPressureLevel(
        for event: DispatchSource.MemoryPressureEvent
    ) -> HostPressureLevel {
        if event.contains(.critical) {
            return .critical
        }
        if event.contains(.warning) {
            return .warning
        }
        if event.contains(.normal) {
            return .nominal
        }
        return .unknown
    }

    /// Creates an unactivated source; the caller owns activation and cancellation.
    public static func makeMemoryPressureSource(
        queue: DispatchQueue? = nil,
        onEvent: @escaping @Sendable (HostPressureLevel) -> Void
    ) -> any DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: .all,
            queue: queue
        )
        source.setEventHandler {
            onEvent(Self.memoryPressureLevel(for: source.data))
        }
        return source
    }

    private func diskPressureSnapshot() -> HostDiskPressureSnapshot {
        guard let facts = diskFactsReader.read(for: volumeURL),
              facts.totalBytes > 0,
              facts.availableBytes <= facts.totalBytes else {
            return HostDiskPressureSnapshot(level: .unknown)
        }

        let availablePercent = Double(facts.availableBytes) / Double(facts.totalBytes) * 100
        let level: HostPressureLevel
        if availablePercent <= diskPressureThresholds.criticalAvailablePercent {
            level = .critical
        } else if availablePercent <= diskPressureThresholds.warningAvailablePercent {
            level = .warning
        } else {
            level = .nominal
        }
        return HostDiskPressureSnapshot(
            level: level,
            availableBytes: facts.availableBytes,
            totalBytes: facts.totalBytes
        )
    }
}
