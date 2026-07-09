import XCTest
@testable import HostwrightCore
@testable import HostwrightHealth

final class HostwrightHealthTests: XCTestCase {
    func testCompatibilityChecksReportUnsupportedPlatform() {
        let checks = DoctorScaffold.compatibilityChecks(
            for: PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64")
        )

        XCTAssertEqual(checks.count, 2)
        XCTAssertTrue(DoctorReport(checks: checks).hasFailures)
        XCTAssertEqual(checks.map(\.identifier), [.appleSilicon, .macOSVersion])
    }

    func testDoctorReportsMissingAppleContainerAsWarning() {
        let report = HostwrightDoctor.report(
            inputs: DoctorInputs(
                operatingSystemDescription: "macOS 26.5",
                platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
                swiftVersion: "Swift 6.3.3",
                containerExecutablePath: nil,
                manifestExists: false
            )
        )

        XCTAssertTrue(report.checks.contains { $0.identifier == .appleContainerCLI && $0.status == .warning })
        XCTAssertFalse(report.hasFailures)
    }

    func testDoctorResourceIntelligenceWarnsOnSeriousThermalState() {
        let snapshot = ResourceIntelligenceSnapshot(
            method: .fixture,
            operatingSystemDescription: "macOS 26.5",
            platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
            physicalMemoryBytes: 68_719_476_736,
            activeProcessorCount: 12,
            thermalState: .serious,
            appleContainerExecutablePath: "/usr/local/bin/container",
            appleContainerVersion: "container 1.0.0",
            workloadProfile: .localContainersGeneral
        )

        let report = HostwrightDoctor.report(
            inputs: DoctorInputs(
                operatingSystemDescription: "macOS 26.5",
                platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
                swiftVersion: "Swift 6.3.3",
                containerExecutablePath: "/usr/local/bin/container",
                manifestExists: true,
                resourceSnapshot: snapshot
            )
        )

        XCTAssertTrue(report.checks.contains { $0.identifier == .resourceIntelligence && $0.status == .warning })
        XCTAssertFalse(report.hasFailures)
    }

    func testResourceReportCapturesMeasurementMethodHardwareLimitsAndUnknowns() {
        let snapshot = ResourceIntelligenceSnapshot(
            method: .fixture,
            operatingSystemDescription: "macOS 26.5",
            platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
            physicalMemoryBytes: 68_719_476_736,
            activeProcessorCount: 12,
            thermalState: .nominal,
            appleContainerExecutablePath: "/usr/local/bin/container",
            appleContainerVersion: "container 1.0.0",
            workloadProfile: .localAIModelMemoryPressure,
            imageArchitectures: [
                ResourceImageArchitectureEvidence(
                    imageReference: "example.local/worker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    reportedArchitecture: "linux/amd64"
                )
            ]
        )

        let report = ResourceIntelligenceReport(snapshot: snapshot)

        XCTAssertEqual(report.measurementMethod, .fixture)
        XCTAssertEqual(report.hardware.architecture, "arm64")
        XCTAssertEqual(report.hardware.physicalMemoryBytes, 68_719_476_736)
        XCTAssertEqual(report.hardware.activeProcessorCount, 12)
        XCTAssertEqual(report.operatingSystem.macOSMajorVersion, 26)
        XCTAssertEqual(report.appleContainer.versionObservation.status, .observed)
        XCTAssertEqual(report.workloadProfile.identifier, "local-ai-model-memory-pressure")
        XCTAssertEqual(report.memoryPressure.status, .unmeasured)
        XCTAssertEqual(report.bootLatency.status, .unmeasured)
        XCTAssertEqual(report.pollingOverhead.status, .unmeasured)
        XCTAssertEqual(report.sleepWake.status, .unmeasured)
        XCTAssertEqual(report.battery.status, .unmeasured)
        XCTAssertEqual(report.thermal.status, .observed)
        XCTAssertEqual(report.architectureWarnings.count, 1)
        XCTAssertTrue(report.architectureWarnings[0].message.contains("Rosetta"))
        XCTAssertTrue(report.limits.contains("No production density or capacity guarantee."))
        XCTAssertTrue(report.limits.contains("No GPU, ANE, Metal, Core ML, MLX, or accelerator scheduling support."))
        XCTAssertTrue(report.limits.contains("No telemetry upload; reports are local diagnostics only."))
    }

    func testCurrentResourceSnapshotUsesLocalProcessInfoWithoutContainerVersionExecution() {
        let snapshot = ResourceIntelligenceSnapshot.current(
            operatingSystemDescription: "macOS local test",
            platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
            appleContainerExecutablePath: "/usr/local/bin/container"
        )

        XCTAssertEqual(snapshot.method, .localProcessInfoSnapshot)
        XCTAssertEqual(snapshot.appleContainerExecutablePath, "/usr/local/bin/container")
        XCTAssertNil(snapshot.appleContainerVersion)
        XCTAssertNotNil(snapshot.physicalMemoryBytes)
        XCTAssertGreaterThan(snapshot.physicalMemoryBytes ?? 0, 0)
        XCTAssertNotNil(snapshot.activeProcessorCount)
        XCTAssertGreaterThan(snapshot.activeProcessorCount ?? 0, 0)
    }

    func testArchitectureWarningsRequireEvidenceAndArm64Host() {
        let warnings = ResourceArchitectureEvaluator.warnings(
            evidence: [
                ResourceImageArchitectureEvidence(imageReference: "local/arm", reportedArchitecture: "arm64"),
                ResourceImageArchitectureEvidence(imageReference: "local/unknown", reportedArchitecture: nil),
                ResourceImageArchitectureEvidence(imageReference: "local/amd64", reportedArchitecture: "amd64"),
                ResourceImageArchitectureEvidence(imageReference: "local/x86", reportedArchitecture: "x86_64"),
                ResourceImageArchitectureEvidence(imageReference: "local/linux", reportedArchitecture: "linux/amd64")
            ],
            hostArchitecture: "arm64"
        )

        XCTAssertEqual(warnings.map(\.imageReference), ["local/amd64", "local/x86", "local/linux"])
        XCTAssertTrue(warnings.allSatisfy { $0.message.contains("Rosetta") })

        let nonArmHostWarnings = ResourceArchitectureEvaluator.warnings(
            evidence: [
                ResourceImageArchitectureEvidence(imageReference: "local/amd64", reportedArchitecture: "amd64")
            ],
            hostArchitecture: "x86_64"
        )
        XCTAssertTrue(nonArmHostWarnings.isEmpty)
    }

    func testResourceReportParserLoadsFixtureShape() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "resource-report-phase26", withExtension: "json"))
        let text = try String(contentsOf: url, encoding: .utf8)

        let report = try ResourceIntelligenceReportParser.parseReport(text)

        XCTAssertEqual(report.measurementMethod, .fixture)
        XCTAssertEqual(report.appleContainer.version, "container 1.0.0")
        XCTAssertEqual(report.memoryPressure.status, .unmeasured)
        XCTAssertEqual(report.battery.status, .unmeasured)
        XCTAssertEqual(report.architectureWarnings.first?.reportedArchitecture, "linux/amd64")
        XCTAssertTrue(report.limits.contains("No runtime mutation, image pull, or container lifecycle action."))
    }

    func testBenchmarkLabDryRunReportRecordsEnvironmentAndNoMutationPolicy() {
        let resourceReport = ResourceIntelligenceReport(
            snapshot: ResourceIntelligenceSnapshot(
                method: .fixture,
                operatingSystemDescription: "macOS 26.5",
                platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
                physicalMemoryBytes: 25_769_803_776,
                activeProcessorCount: 12,
                thermalState: .nominal,
                appleContainerExecutablePath: "/usr/local/bin/container",
                appleContainerVersion: "container 1.0.0",
                workloadProfile: .localContainersGeneral
            )
        )

        let report = BenchmarkLabReport.dryRun(
            profileID: "phase36-dry-run",
            recordedAt: "2026-07-09T00:00:00Z",
            resourceReport: resourceReport
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.environment.hardware.architecture, "arm64")
        XCTAssertEqual(report.environment.appleContainer.version, "container 1.0.0")
        XCTAssertEqual(report.resourcePolicy.disposableResourceNamePrefix, "hostwright-benchmark-")
        XCTAssertTrue(report.resourcePolicy.requiresHostwrightOwnedResources)
        XCTAssertFalse(report.resourcePolicy.allowsImagePull)
        XCTAssertFalse(report.resourcePolicy.allowsRuntimeMutation)
        XCTAssertFalse(report.resourcePolicy.allowsBroadCleanup)
        XCTAssertEqual(Set(report.observations.map(\.dimension)), Set(BenchmarkMeasurementDimension.allCases))
        XCTAssertTrue(report.observations.allSatisfy { $0.observation.status == .unmeasured })
        XCTAssertTrue(report.limits.contains("No performance marketing claim."))
    }

    func testBenchmarkLabParserLoadsFixtureAndRejectsUnsafePolicies() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "benchmark-report-phase36", withExtension: "json"))
        let text = try String(contentsOf: url, encoding: .utf8)

        let report = try BenchmarkLabReportParser.parseReport(text)

        XCTAssertEqual(report.profileID, "phase36-dry-run")
        XCTAssertEqual(report.resourcePolicy.disposableResourceNamePrefix, "hostwright-benchmark-")
        XCTAssertEqual(report.observations.count, BenchmarkMeasurementDimension.allCases.count)
        XCTAssertTrue(report.limits.contains("No cloud telemetry."))

        var unsafe = report
        unsafe = BenchmarkLabReport(
            schemaVersion: unsafe.schemaVersion,
            profileID: unsafe.profileID,
            recordedAt: unsafe.recordedAt,
            environment: unsafe.environment,
            resourcePolicy: BenchmarkResourcePolicy(
                disposableResourceNamePrefix: "benchmark-",
                requiresHostwrightOwnedResources: true,
                allowsImagePull: false,
                allowsRuntimeMutation: false,
                allowsBroadCleanup: false,
                cleanupInstructions: unsafe.resourcePolicy.cleanupInstructions
            ),
            observations: unsafe.observations,
            limits: unsafe.limits
        )

        XCTAssertThrowsError(try BenchmarkLabReportParser.validate(unsafe)) { error in
            XCTAssertEqual(
                error as? BenchmarkLabReportValidationError,
                .unsafeResourcePolicy("disposable resource prefix must start with hostwright-")
            )
        }
    }
}
