import Foundation

public enum BenchmarkMeasurementDimension: String, Codable, Equatable, CaseIterable, Sendable {
    case memoryPressure
    case bootLatency
    case pollingOverhead
    case battery
    case thermal
    case sleepWake
    case appleContainerVersionDrift
}

public struct BenchmarkEnvironmentReport: Codable, Equatable, Sendable {
    public let hardware: ResourceHardwareReport
    public let operatingSystem: ResourceOperatingSystemReport
    public let appleContainer: ResourceAppleContainerReport
    public let workloadProfile: ResourceWorkloadProfile

    public init(resourceReport: ResourceIntelligenceReport) {
        hardware = resourceReport.hardware
        operatingSystem = resourceReport.operatingSystem
        appleContainer = resourceReport.appleContainer
        workloadProfile = resourceReport.workloadProfile
    }

    public init(
        hardware: ResourceHardwareReport,
        operatingSystem: ResourceOperatingSystemReport,
        appleContainer: ResourceAppleContainerReport,
        workloadProfile: ResourceWorkloadProfile
    ) {
        self.hardware = hardware
        self.operatingSystem = operatingSystem
        self.appleContainer = appleContainer
        self.workloadProfile = workloadProfile
    }
}

public struct BenchmarkResourcePolicy: Codable, Equatable, Sendable {
    public let disposableResourceNamePrefix: String
    public let requiresHostwrightOwnedResources: Bool
    public let allowsImagePull: Bool
    public let allowsRuntimeMutation: Bool
    public let allowsBroadCleanup: Bool
    public let cleanupInstructions: String

    public init(
        disposableResourceNamePrefix: String,
        requiresHostwrightOwnedResources: Bool,
        allowsImagePull: Bool,
        allowsRuntimeMutation: Bool,
        allowsBroadCleanup: Bool,
        cleanupInstructions: String
    ) {
        self.disposableResourceNamePrefix = disposableResourceNamePrefix
        self.requiresHostwrightOwnedResources = requiresHostwrightOwnedResources
        self.allowsImagePull = allowsImagePull
        self.allowsRuntimeMutation = allowsRuntimeMutation
        self.allowsBroadCleanup = allowsBroadCleanup
        self.cleanupInstructions = cleanupInstructions
    }

    public static let dryRunOnly = BenchmarkResourcePolicy(
        disposableResourceNamePrefix: "hostwright-benchmark-",
        requiresHostwrightOwnedResources: true,
        allowsImagePull: false,
        allowsRuntimeMutation: false,
        allowsBroadCleanup: false,
        cleanupInstructions: "Dry-run reports do not create resources. Future live runs must clean up exact Hostwright-owned resource identifiers only."
    )
}

public struct BenchmarkObservation: Codable, Equatable, Sendable {
    public let dimension: BenchmarkMeasurementDimension
    public let observation: ResourceObservation

    public init(dimension: BenchmarkMeasurementDimension, observation: ResourceObservation) {
        self.dimension = dimension
        self.observation = observation
    }
}

public struct BenchmarkLabReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let profileID: String
    public let recordedAt: String
    public let environment: BenchmarkEnvironmentReport
    public let resourcePolicy: BenchmarkResourcePolicy
    public let observations: [BenchmarkObservation]
    public let limits: [String]

    public init(
        schemaVersion: Int = 1,
        profileID: String,
        recordedAt: String,
        environment: BenchmarkEnvironmentReport,
        resourcePolicy: BenchmarkResourcePolicy,
        observations: [BenchmarkObservation],
        limits: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.recordedAt = recordedAt
        self.environment = environment
        self.resourcePolicy = resourcePolicy
        self.observations = observations
        self.limits = limits
    }

    public static func dryRun(
        profileID: String,
        recordedAt: String,
        resourceReport: ResourceIntelligenceReport
    ) -> BenchmarkLabReport {
        BenchmarkLabReport(
            profileID: profileID,
            recordedAt: recordedAt,
            environment: BenchmarkEnvironmentReport(resourceReport: resourceReport),
            resourcePolicy: .dryRunOnly,
            observations: BenchmarkMeasurementDimension.allCases.map { dimension in
                BenchmarkObservation(
                    dimension: dimension,
                    observation: .unmeasured(
                        method: resourceReport.measurementMethod,
                        note: "Phase 36 benchmark lab dry-run records methodology only; this dimension was not measured."
                    )
                )
            },
            limits: [
                "No runtime mutation.",
                "No image pull.",
                "No broad cleanup.",
                "No cloud telemetry.",
                "No performance marketing claim."
            ]
        )
    }
}

public enum BenchmarkLabReportParser {
    public static func parseReport(_ text: String) throws -> BenchmarkLabReport {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        let report = try decoder.decode(BenchmarkLabReport.self, from: data)
        try validate(report)
        return report
    }

    public static func validate(_ report: BenchmarkLabReport) throws {
        guard report.schemaVersion == 1 else {
            throw BenchmarkLabReportValidationError.unsupportedSchemaVersion(report.schemaVersion)
        }
        guard !report.profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BenchmarkLabReportValidationError.invalidProfile("profileID is required")
        }
        guard report.resourcePolicy.disposableResourceNamePrefix.hasPrefix("hostwright-") else {
            throw BenchmarkLabReportValidationError.unsafeResourcePolicy("disposable resource prefix must start with hostwright-")
        }
        guard report.resourcePolicy.requiresHostwrightOwnedResources else {
            throw BenchmarkLabReportValidationError.unsafeResourcePolicy("benchmarks must require Hostwright-owned resources")
        }
        guard !report.resourcePolicy.allowsImagePull else {
            throw BenchmarkLabReportValidationError.unsafeResourcePolicy("benchmark reports must not allow image pulls by default")
        }
        guard !report.resourcePolicy.allowsRuntimeMutation else {
            throw BenchmarkLabReportValidationError.unsafeResourcePolicy("benchmark reports must not allow runtime mutation by default")
        }
        guard !report.resourcePolicy.allowsBroadCleanup else {
            throw BenchmarkLabReportValidationError.unsafeResourcePolicy("benchmark reports must not allow broad cleanup")
        }
        let dimensions = Set(report.observations.map(\.dimension))
        for dimension in BenchmarkMeasurementDimension.allCases where !dimensions.contains(dimension) {
            throw BenchmarkLabReportValidationError.missingObservation(dimension.rawValue)
        }
    }
}

public enum BenchmarkLabReportValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidProfile(String)
    case unsafeResourcePolicy(String)
    case missingObservation(String)
}
