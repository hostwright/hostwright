import Foundation
import HostwrightCore

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

public struct BenchmarkImageReport: Codable, Equatable, Sendable {
    public let requestedReference: String
    public let descriptorDigest: String?
    public let variantDigest: String?
    public let architecture: String?
    public let operatingSystem: String?
    public let status: ResourceObservationStatus
    public let note: String

    public init(
        requestedReference: String,
        descriptorDigest: String?,
        variantDigest: String?,
        architecture: String?,
        operatingSystem: String?,
        status: ResourceObservationStatus,
        note: String
    ) {
        self.requestedReference = requestedReference
        self.descriptorDigest = descriptorDigest
        self.variantDigest = variantDigest
        self.architecture = architecture
        self.operatingSystem = operatingSystem
        self.status = status
        self.note = note
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

    public static let confirmedLive = BenchmarkResourcePolicy(
        disposableResourceNamePrefix: "hostwright-v2-bench-",
        requiresHostwrightOwnedResources: true,
        allowsImagePull: false,
        allowsRuntimeMutation: true,
        allowsBroadCleanup: false,
        cleanupInstructions: "Wait for each bounded benchmark process to exit, delete only its exact versioned Hostwright-owned identifier, then verify it is absent."
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

public struct BenchmarkResourceUsageSample: Codable, Equatable, Sendable {
    public let cpuUsageMicroseconds: UInt64
    public let memoryUsageBytes: UInt64
    public let memoryLimitBytes: UInt64
    public let networkReceiveBytes: UInt64
    public let networkTransmitBytes: UInt64
    public let blockReadBytes: UInt64
    public let blockWriteBytes: UInt64
    public let processCount: Int

    public init(
        cpuUsageMicroseconds: UInt64,
        memoryUsageBytes: UInt64,
        memoryLimitBytes: UInt64,
        networkReceiveBytes: UInt64,
        networkTransmitBytes: UInt64,
        blockReadBytes: UInt64,
        blockWriteBytes: UInt64,
        processCount: Int
    ) {
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkReceiveBytes = networkReceiveBytes
        self.networkTransmitBytes = networkTransmitBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.processCount = processCount
    }
}

public struct BenchmarkIterationReport: Codable, Equatable, Sendable {
    public let sequence: Int
    public let resourceIdentifier: String
    public let createDurationMilliseconds: Int
    public let startDurationMilliseconds: Int
    public let bootLatencyMilliseconds: Int
    public let observationPollDurationsMilliseconds: [Int]
    public let resourceUsage: BenchmarkResourceUsageSample
    public let thermalState: ResourcePressureLevel
    public let batteryChargePercent: Double?

    public init(
        sequence: Int,
        resourceIdentifier: String,
        createDurationMilliseconds: Int,
        startDurationMilliseconds: Int,
        bootLatencyMilliseconds: Int,
        observationPollDurationsMilliseconds: [Int],
        resourceUsage: BenchmarkResourceUsageSample,
        thermalState: ResourcePressureLevel,
        batteryChargePercent: Double?
    ) {
        self.sequence = sequence
        self.resourceIdentifier = resourceIdentifier
        self.createDurationMilliseconds = createDurationMilliseconds
        self.startDurationMilliseconds = startDurationMilliseconds
        self.bootLatencyMilliseconds = bootLatencyMilliseconds
        self.observationPollDurationsMilliseconds = observationPollDurationsMilliseconds
        self.resourceUsage = resourceUsage
        self.thermalState = thermalState
        self.batteryChargePercent = batteryChargePercent
    }
}

public struct BenchmarkProtocolRecord: Codable, Equatable, Sendable {
    public let identifier: String
    public let status: ResourceObservationStatus
    public let method: String
    public let note: String

    public init(identifier: String, status: ResourceObservationStatus, method: String, note: String) {
        self.identifier = identifier
        self.status = status
        self.method = method
        self.note = note
    }
}

public struct BenchmarkSleepWakeSample: Codable, Equatable, Sendable {
    public let requestedWindowSeconds: Int
    public let beforeTimestamp: String
    public let afterTimestamp: String
    public let wallElapsedMilliseconds: Int
    public let uptimeElapsedMilliseconds: Int
    public let detectedSleepGapMilliseconds: Int
    public let postWakeLifecycleState: String

    public init(
        requestedWindowSeconds: Int,
        beforeTimestamp: String,
        afterTimestamp: String,
        wallElapsedMilliseconds: Int,
        uptimeElapsedMilliseconds: Int,
        detectedSleepGapMilliseconds: Int,
        postWakeLifecycleState: String
    ) {
        self.requestedWindowSeconds = requestedWindowSeconds
        self.beforeTimestamp = beforeTimestamp
        self.afterTimestamp = afterTimestamp
        self.wallElapsedMilliseconds = wallElapsedMilliseconds
        self.uptimeElapsedMilliseconds = uptimeElapsedMilliseconds
        self.detectedSleepGapMilliseconds = detectedSleepGapMilliseconds
        self.postWakeLifecycleState = postWakeLifecycleState
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
    public let evidence: HostwrightEvidenceReport?
    public let iterations: [BenchmarkIterationReport]?
    public let protocols: [BenchmarkProtocolRecord]?
    public let sleepWakeSample: BenchmarkSleepWakeSample?
    public let image: BenchmarkImageReport?

    public init(
        schemaVersion: Int = 1,
        profileID: String,
        recordedAt: String,
        environment: BenchmarkEnvironmentReport,
        resourcePolicy: BenchmarkResourcePolicy,
        observations: [BenchmarkObservation],
        limits: [String],
        evidence: HostwrightEvidenceReport? = nil,
        iterations: [BenchmarkIterationReport]? = nil,
        protocols: [BenchmarkProtocolRecord]? = nil,
        sleepWakeSample: BenchmarkSleepWakeSample? = nil,
        image: BenchmarkImageReport? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.recordedAt = recordedAt
        self.environment = environment
        self.resourcePolicy = resourcePolicy
        self.observations = observations
        self.limits = limits
        self.evidence = evidence
        self.iterations = iterations
        self.protocols = protocols
        self.sleepWakeSample = sleepWakeSample
        self.image = image
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
        guard report.schemaVersion == 1 || report.schemaVersion == 2 else {
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
        guard !report.resourcePolicy.allowsBroadCleanup else {
            throw BenchmarkLabReportValidationError.unsafeResourcePolicy("benchmark reports must not allow broad cleanup")
        }
        let dimensions = report.observations.map(\.dimension)
        guard Set(dimensions).count == dimensions.count else {
            throw BenchmarkLabReportValidationError.duplicateObservation
        }
        for dimension in BenchmarkMeasurementDimension.allCases where !dimensions.contains(dimension) {
            throw BenchmarkLabReportValidationError.missingObservation(dimension.rawValue)
        }

        if report.schemaVersion == 1 {
            guard !report.resourcePolicy.allowsRuntimeMutation,
                  report.evidence == nil,
                  report.iterations == nil,
                  report.image == nil else {
                throw BenchmarkLabReportValidationError.unsafeResourcePolicy("schema version 1 reports are dry-run or fixture-only")
            }
            return
        }

        guard report.resourcePolicy.allowsRuntimeMutation,
              report.resourcePolicy.disposableResourceNamePrefix == "hostwright-v2-bench-" else {
            throw BenchmarkLabReportValidationError.unsafeResourcePolicy(
                "schema version 2 requires the confirmed exact-resource benchmark policy"
            )
        }
        guard report.profileID.range(of: "^phase36-live-(?:[3-9]|10)-samples$", options: .regularExpression) != nil else {
            throw BenchmarkLabReportValidationError.invalidProfile("schema version 2 requires a bounded live profile identifier")
        }
        guard let requestedSampleCount = Int(report.profileID.split(separator: "-")[2]) else {
            throw BenchmarkLabReportValidationError.invalidProfile("schema version 2 profile omitted sample count")
        }
        guard let evidence = report.evidence,
              evidence.evidenceClass == .hardwareBenchmark else {
            throw BenchmarkLabReportValidationError.missingEvidence
        }
        guard let image = report.image,
              !image.requestedReference.isEmpty,
              !image.note.isEmpty else {
            throw BenchmarkLabReportValidationError.invalidSample
        }
        if image.status == .observed {
            guard let descriptorDigest = image.descriptorDigest,
                  let variantDigest = image.variantDigest,
                  descriptorDigest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil,
                  variantDigest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil,
                  image.architecture?.isEmpty == false,
                  image.operatingSystem?.isEmpty == false,
                  evidence.environment.toolVersions["image-descriptor"] == descriptorDigest else {
                throw BenchmarkLabReportValidationError.invalidSample
            }
        } else {
            guard image.descriptorDigest == nil,
                  image.variantDigest == nil,
                  image.architecture == nil,
                  image.operatingSystem == nil,
                  evidence.environment.toolVersions["image-descriptor"] == "unavailable" else {
                throw BenchmarkLabReportValidationError.invalidSample
            }
        }
        do {
            try evidence.validate()
        } catch {
            throw BenchmarkLabReportValidationError.invalidEvidence(String(describing: error))
        }
        guard report.recordedAt == evidence.recordedAt,
              report.environment.operatingSystem.description == evidence.environment.operatingSystem,
              report.environment.hardware.architecture == evidence.environment.architecture,
              report.environment.hardware.physicalMemoryBytes == evidence.environment.memoryBytes,
              (report.environment.appleContainer.version ?? "unavailable") == evidence.environment.toolVersions["apple-container"],
              report.observations.allSatisfy({ $0.observation.method == .liveHardwareBenchmark }) else {
            throw BenchmarkLabReportValidationError.invalidEvidence("benchmark payload is not bound to its evidence environment")
        }
        guard report.observations.allSatisfy({ item in
            !item.observation.note.isEmpty &&
                (item.observation.status == .observed
                    ? item.observation.value?.isEmpty == false
                    : item.observation.value == nil)
        }) else {
            throw BenchmarkLabReportValidationError.invalidSample
        }
        guard let protocols = report.protocols,
              protocols.count == 2,
              Set(protocols.map(\.identifier)) == Set(["bounded-container-v1", "sleep-wake-resume-v1"]) else {
            throw BenchmarkLabReportValidationError.invalidSample
        }
        guard let iterations = report.iterations else {
            throw BenchmarkLabReportValidationError.insufficientSamples
        }
        guard iterations.count <= requestedSampleCount else {
            throw BenchmarkLabReportValidationError.invalidSample
        }
        if evidence.status == .passed || (evidence.status == .blocked && !iterations.isEmpty) {
            guard iterations.count >= 3 else {
                throw BenchmarkLabReportValidationError.insufficientSamples
            }
            guard image.status == .observed else {
                throw BenchmarkLabReportValidationError.invalidSample
            }
        }
        let identifiers = iterations.map(\.resourceIdentifier)
        let cleanupIdentifierPattern = "^hostwright-v2-bench-probe-[a-f0-9]{32}$"
        guard Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy({
                  $0.range(of: cleanupIdentifierPattern, options: .regularExpression) != nil
              }),
              evidence.cleanup.exactResourceIdentifiers.allSatisfy({
                  $0.range(of: cleanupIdentifierPattern, options: .regularExpression) != nil
              }),
              Set(identifiers).isSubset(of: Set(evidence.cleanup.exactResourceIdentifiers)) else {
            throw BenchmarkLabReportValidationError.invalidCleanupEvidence
        }
        if evidence.status != .failed, !iterations.isEmpty,
           evidence.cleanup.exactResourceIdentifiers != identifiers {
            throw BenchmarkLabReportValidationError.invalidCleanupEvidence
        }
        guard iterations.enumerated().allSatisfy({ offset, iteration in
            iteration.sequence == offset + 1 &&
                iteration.createDurationMilliseconds >= 0 &&
                iteration.startDurationMilliseconds >= 0 &&
                iteration.bootLatencyMilliseconds >= 0 &&
                !iteration.observationPollDurationsMilliseconds.isEmpty &&
                iteration.observationPollDurationsMilliseconds.allSatisfy { $0 >= 0 } &&
                iteration.resourceUsage.processCount >= 0 &&
                iteration.resourceUsage.memoryLimitBytes > 0 &&
                iteration.resourceUsage.memoryUsageBytes <= iteration.resourceUsage.memoryLimitBytes &&
                (iteration.batteryChargePercent.map { (0...100).contains($0) } ?? true)
        }) else {
            throw BenchmarkLabReportValidationError.invalidSample
        }
        let boundedProtocol = protocols.first { $0.identifier == "bounded-container-v1" }
        let sleepProtocol = protocols.first { $0.identifier == "sleep-wake-resume-v1" }
        let sleepObservation = report.observations.first { $0.dimension == .sleepWake }
        guard boundedProtocol?.status == (iterations.count == requestedSampleCount ? .observed : .unmeasured),
              sleepProtocol?.status == sleepObservation?.observation.status else {
            throw BenchmarkLabReportValidationError.invalidSample
        }
        let observedCount = report.observations.filter { $0.observation.status == .observed }.count
        let blockedCount = report.observations.count - observedCount
        guard evidence.rawResults.passed == observedCount,
              evidence.rawResults.blocked == blockedCount,
              evidence.rawResults.failed == (evidence.status == .failed ? 1 : 0) else {
            throw BenchmarkLabReportValidationError.invalidEvidence("raw counts do not match benchmark observations")
        }
        if evidence.status == .passed,
           report.observations.contains(where: { $0.observation.status != .observed }) {
            throw BenchmarkLabReportValidationError.invalidEvidence(
                "passing hardware evidence cannot contain unavailable or unmeasured dimensions"
            )
        }
        if let sleepWake = report.observations.first(where: { $0.dimension == .sleepWake }),
           sleepWake.observation.status == .observed {
            guard let sample = report.sleepWakeSample,
                  sample.requestedWindowSeconds >= 15,
                  sample.wallElapsedMilliseconds >= 0,
                  sample.uptimeElapsedMilliseconds >= 0,
                  sample.detectedSleepGapMilliseconds >= 2_000,
                  sample.detectedSleepGapMilliseconds == max(
                    0,
                    sample.wallElapsedMilliseconds - sample.uptimeElapsedMilliseconds
                  ),
                  !sample.postWakeLifecycleState.isEmpty else {
                throw BenchmarkLabReportValidationError.invalidSample
            }
        }
    }
}

public enum BenchmarkLabReportValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidProfile(String)
    case unsafeResourcePolicy(String)
    case missingObservation(String)
    case duplicateObservation
    case missingEvidence
    case invalidEvidence(String)
    case insufficientSamples
    case invalidCleanupEvidence
    case invalidSample
}
