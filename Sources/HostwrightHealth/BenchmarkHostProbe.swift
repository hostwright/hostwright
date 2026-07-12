import Darwin
import Foundation
import HostwrightCore
import IOKit.ps

public struct BenchmarkBatterySnapshot: Codable, Equatable, Sendable {
    public let chargePercent: Double
    public let powerSource: String
    public let isCharging: Bool?

    public init(chargePercent: Double, powerSource: String, isCharging: Bool?) {
        self.chargePercent = chargePercent
        self.powerSource = powerSource
        self.isCharging = isCharging
    }
}

public struct BenchmarkHostSnapshot: Equatable, Sendable {
    public let operatingSystem: String
    public let operatingSystemBuild: String
    public let architecture: String
    public let hardwareModel: String
    public let physicalMemoryBytes: Int
    public let activeProcessorCount: Int
    public let thermalState: ResourcePressureLevel
    public let battery: BenchmarkBatterySnapshot?

    public init(
        operatingSystem: String,
        operatingSystemBuild: String,
        architecture: String,
        hardwareModel: String,
        physicalMemoryBytes: Int,
        activeProcessorCount: Int,
        thermalState: ResourcePressureLevel,
        battery: BenchmarkBatterySnapshot?
    ) {
        self.operatingSystem = operatingSystem
        self.operatingSystemBuild = operatingSystemBuild
        self.architecture = architecture
        self.hardwareModel = hardwareModel
        self.physicalMemoryBytes = physicalMemoryBytes
        self.activeProcessorCount = activeProcessorCount
        self.thermalState = thermalState
        self.battery = battery
    }

    public static var current: BenchmarkHostSnapshot {
        let memory = min(ProcessInfo.processInfo.physicalMemory, UInt64(Int.max))
        return BenchmarkHostSnapshot(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            operatingSystemBuild: sysctlString("kern.osversion") ?? "unavailable",
            architecture: PlatformSnapshot.current.architecture,
            hardwareModel: sysctlString("hw.model") ?? "unavailable",
            physicalMemoryBytes: Int(memory),
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            thermalState: ResourcePressureLevel(processInfoThermalState: ProcessInfo.processInfo.thermalState),
            battery: batterySnapshot()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        let payload = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: payload, as: UTF8.self)
    }

    private static func batterySnapshot() -> BenchmarkBatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0 else {
                continue
            }
            let powerSource = description[kIOPSPowerSourceStateKey] as? String ?? "unavailable"
            return BenchmarkBatterySnapshot(
                chargePercent: current.doubleValue / maximum.doubleValue * 100,
                powerSource: powerSource,
                isCharging: description[kIOPSIsChargingKey] as? Bool
            )
        }
        return nil
    }
}
