import Foundation
import HostwrightCore

public enum ResourceMeasurementMethod: String, Codable, Equatable, Sendable {
    case localProcessInfoSnapshot
    case fixture
    case liveHardwareBenchmark
}

public enum ResourceObservationStatus: String, Codable, Equatable, Sendable {
    case observed
    case unavailable
    case unmeasured
}

public enum ResourcePressureLevel: String, Codable, Equatable, Sendable {
    case unknown
    case nominal
    case fair
    case serious
    case critical
}

public struct ResourceObservation: Codable, Equatable, Sendable {
    public let status: ResourceObservationStatus
    public let value: String?
    public let unit: String?
    public let method: ResourceMeasurementMethod
    public let note: String

    public init(
        status: ResourceObservationStatus,
        value: String?,
        unit: String?,
        method: ResourceMeasurementMethod,
        note: String
    ) {
        self.status = status
        self.value = value
        self.unit = unit
        self.method = method
        self.note = note
    }

    public static func unmeasured(method: ResourceMeasurementMethod, note: String) -> ResourceObservation {
        ResourceObservation(status: .unmeasured, value: nil, unit: nil, method: method, note: note)
    }
}

public struct ResourceWorkloadProfile: Codable, Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let notes: [String]

    public init(identifier: String, name: String, notes: [String]) {
        self.identifier = identifier
        self.name = name
        self.notes = notes
    }

    public static let localContainersGeneral = ResourceWorkloadProfile(
        identifier: "local-containers-general",
        name: "Local containers, general development",
        notes: [
            "Reports host facts only; it does not estimate production density.",
            "Does not schedule or reserve resources."
        ]
    )

    public static let localAIModelMemoryPressure = ResourceWorkloadProfile(
        identifier: "local-ai-model-memory-pressure",
        name: "Local AI workload memory-pressure study",
        notes: [
            "Describes future measurement inputs for unified-memory pressure.",
            "Does not enable GPU, ANE, Metal, Core ML, MLX, or accelerator scheduling."
        ]
    )
}

public struct ResourceHardwareReport: Codable, Equatable, Sendable {
    public let architecture: String
    public let activeProcessorCount: Int?
    public let physicalMemoryBytes: Int?
    public let unifiedMemoryNote: String

    public init(
        architecture: String,
        activeProcessorCount: Int?,
        physicalMemoryBytes: Int?,
        unifiedMemoryNote: String
    ) {
        self.architecture = architecture
        self.activeProcessorCount = activeProcessorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.unifiedMemoryNote = unifiedMemoryNote
    }
}

public struct ResourceOperatingSystemReport: Codable, Equatable, Sendable {
    public let description: String
    public let macOSMajorVersion: Int

    public init(description: String, macOSMajorVersion: Int) {
        self.description = description
        self.macOSMajorVersion = macOSMajorVersion
    }
}

public struct ResourceAppleContainerReport: Codable, Equatable, Sendable {
    public let executablePath: String?
    public let version: String?
    public let versionObservation: ResourceObservation

    public init(executablePath: String?, version: String?, versionObservation: ResourceObservation) {
        self.executablePath = executablePath
        self.version = version
        self.versionObservation = versionObservation
    }
}

public struct ResourceImageArchitectureEvidence: Codable, Equatable, Sendable {
    public let imageReference: String
    public let reportedArchitecture: String?

    public init(imageReference: String, reportedArchitecture: String?) {
        self.imageReference = imageReference
        self.reportedArchitecture = reportedArchitecture
    }
}

public struct ResourceArchitectureWarning: Codable, Equatable, Sendable {
    public let imageReference: String
    public let reportedArchitecture: String
    public let message: String

    public init(imageReference: String, reportedArchitecture: String, message: String) {
        self.imageReference = imageReference
        self.reportedArchitecture = reportedArchitecture
        self.message = message
    }
}

public struct ResourceIntelligenceSnapshot: Equatable, Sendable {
    public let method: ResourceMeasurementMethod
    public let operatingSystemDescription: String
    public let platform: PlatformSnapshot
    public let physicalMemoryBytes: Int?
    public let activeProcessorCount: Int?
    public let thermalState: ResourcePressureLevel
    public let appleContainerExecutablePath: String?
    public let appleContainerVersion: String?
    public let workloadProfile: ResourceWorkloadProfile
    public let imageArchitectures: [ResourceImageArchitectureEvidence]

    public init(
        method: ResourceMeasurementMethod,
        operatingSystemDescription: String,
        platform: PlatformSnapshot,
        physicalMemoryBytes: Int?,
        activeProcessorCount: Int?,
        thermalState: ResourcePressureLevel,
        appleContainerExecutablePath: String?,
        appleContainerVersion: String?,
        workloadProfile: ResourceWorkloadProfile,
        imageArchitectures: [ResourceImageArchitectureEvidence] = []
    ) {
        self.method = method
        self.operatingSystemDescription = operatingSystemDescription
        self.platform = platform
        self.physicalMemoryBytes = physicalMemoryBytes
        self.activeProcessorCount = activeProcessorCount
        self.thermalState = thermalState
        self.appleContainerExecutablePath = appleContainerExecutablePath
        self.appleContainerVersion = appleContainerVersion
        self.workloadProfile = workloadProfile
        self.imageArchitectures = imageArchitectures
    }

    public static func current(
        operatingSystemDescription: String,
        platform: PlatformSnapshot,
        appleContainerExecutablePath: String?
    ) -> ResourceIntelligenceSnapshot {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let boundedPhysicalMemory = min(physicalMemory, UInt64(Int.max))
        return ResourceIntelligenceSnapshot(
            method: .localProcessInfoSnapshot,
            operatingSystemDescription: operatingSystemDescription,
            platform: platform,
            physicalMemoryBytes: Int(boundedPhysicalMemory),
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            thermalState: ResourcePressureLevel(processInfoThermalState: ProcessInfo.processInfo.thermalState),
            appleContainerExecutablePath: appleContainerExecutablePath,
            appleContainerVersion: nil,
            workloadProfile: .localContainersGeneral
        )
    }
}

public struct ResourceIntelligenceReport: Codable, Equatable, Sendable {
    public let measurementMethod: ResourceMeasurementMethod
    public let hardware: ResourceHardwareReport
    public let operatingSystem: ResourceOperatingSystemReport
    public let appleContainer: ResourceAppleContainerReport
    public let workloadProfile: ResourceWorkloadProfile
    public let memoryPressure: ResourceObservation
    public let bootLatency: ResourceObservation
    public let pollingOverhead: ResourceObservation
    public let sleepWake: ResourceObservation
    public let battery: ResourceObservation
    public let thermal: ResourceObservation
    public let architectureWarnings: [ResourceArchitectureWarning]
    public let limits: [String]

    public init(snapshot: ResourceIntelligenceSnapshot) {
        measurementMethod = snapshot.method
        hardware = ResourceHardwareReport(
            architecture: snapshot.platform.architecture,
            activeProcessorCount: snapshot.activeProcessorCount,
            physicalMemoryBytes: snapshot.physicalMemoryBytes,
            unifiedMemoryNote: "Apple silicon uses unified memory; this report records host memory facts, not workload capacity."
        )
        operatingSystem = ResourceOperatingSystemReport(
            description: snapshot.operatingSystemDescription,
            macOSMajorVersion: snapshot.platform.macOSMajorVersion
        )
        let versionObservation: ResourceObservation
        if let version = snapshot.appleContainerVersion, !version.isEmpty {
            versionObservation = ResourceObservation(
                status: .observed,
                value: version,
                unit: nil,
                method: snapshot.method,
                note: "Apple container version came from an injected report snapshot."
            )
        } else {
            versionObservation = ResourceObservation(
                status: .unavailable,
                value: nil,
                unit: nil,
                method: snapshot.method,
                note: "Live doctor does not execute Apple container commands; version is unavailable unless supplied by a fixture."
            )
        }
        appleContainer = ResourceAppleContainerReport(
            executablePath: snapshot.appleContainerExecutablePath,
            version: snapshot.appleContainerVersion,
            versionObservation: versionObservation
        )
        workloadProfile = snapshot.workloadProfile
        memoryPressure = .unmeasured(
            method: snapshot.method,
            note: "Host physical memory is recorded; per-workload memory pressure requires a bounded benchmark run."
        )
        bootLatency = .unmeasured(
            method: snapshot.method,
            note: "Container boot latency is not measured by doctor because doctor does not create or start containers."
        )
        pollingOverhead = .unmeasured(
            method: snapshot.method,
            note: "Polling overhead requires a timed observation loop and is not inferred from a single snapshot."
        )
        sleepWake = .unmeasured(
            method: snapshot.method,
            note: "Sleep/wake behavior requires a controlled long-running runtime proof and is not inferred from local facts."
        )
        battery = .unmeasured(
            method: snapshot.method,
            note: "Battery behavior requires a controlled battery run and is not inferred from local facts."
        )
        thermal = ResourceObservation(
            status: snapshot.thermalState == .unknown ? .unavailable : .observed,
            value: snapshot.thermalState.rawValue,
            unit: nil,
            method: snapshot.method,
            note: "Thermal state is the current host process snapshot and is not a workload capacity guarantee."
        )
        architectureWarnings = ResourceArchitectureEvaluator.warnings(
            evidence: snapshot.imageArchitectures,
            hostArchitecture: snapshot.platform.architecture
        )
        limits = [
            "No production density or capacity guarantee.",
            "No GPU, ANE, Metal, Core ML, MLX, or accelerator scheduling support.",
            "No telemetry upload; reports are local diagnostics only.",
            "No runtime mutation, image pull, or container lifecycle action."
        ]
    }

    public var hasThermalWarning: Bool {
        thermal.value == ResourcePressureLevel.serious.rawValue || thermal.value == ResourcePressureLevel.critical.rawValue
    }
}

public enum ResourceArchitectureEvaluator {
    public static func warnings(
        evidence: [ResourceImageArchitectureEvidence],
        hostArchitecture: String
    ) -> [ResourceArchitectureWarning] {
        guard hostArchitecture == CompatibilityGate.supportedArchitecture else {
            return []
        }

        return evidence.compactMap { item in
            guard let reported = item.reportedArchitecture?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !reported.isEmpty,
                  isNonArm64Architecture(reported) else {
                return nil
            }
            return ResourceArchitectureWarning(
                imageReference: item.imageReference,
                reportedArchitecture: reported,
                message: "Image architecture \(reported) may require Rosetta translation on Apple silicon; verify performance before relying on it."
            )
        }
    }

    private static func isNonArm64Architecture(_ reported: String) -> Bool {
        let normalized = reported.replacingOccurrences(of: "linux/", with: "")
        return normalized == "amd64" || normalized == "x86_64" || normalized == "386" || normalized == "i386"
    }
}

public enum ResourceIntelligenceReportParser {
    public static func parseReport(_ text: String) throws -> ResourceIntelligenceReport {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(ResourceIntelligenceReport.self, from: data)
    }
}

public extension ResourcePressureLevel {
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
