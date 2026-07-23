import Foundation
import XCTest
@testable import HostwrightCLI
import HostwrightCore
import HostwrightHealth
import HostwrightRuntime

final class BenchmarkCommandTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)

    func testParserRequiresAllExplicitLiveEvidenceInputs() throws {
        let report = "/tmp/phase36-report.json"
        let command = try CLICommand.parse(arguments: [
            "benchmark",
            "--image", "docker.io/library/python:alpine",
            "--samples", "3",
            "--report", report,
            "--source-commit", commit,
            "--source-dirty", "true",
            "--expected-container-version", "1.0.0",
            "--confirm-live"
        ])
        XCTAssertEqual(
            command,
            .benchmark(
                options: BenchmarkCLIOptions(
                    image: "docker.io/library/python:alpine",
                    sampleCount: 3,
                    reportPath: report,
                    sourceCommit: commit,
                    sourceDirty: true,
                    expectedContainerVersion: "1.0.0",
                    confirmedLive: true
                )
            )
        )
    }

    func testParserRejectsMissingConfirmationBadCountsAndInvalidCommit() {
        let base = [
            "benchmark", "--image", "python:alpine", "--samples", "3", "--report", "/tmp/report.json",
            "--source-commit", commit, "--source-dirty", "false", "--expected-container-version", "1.0.0"
        ]
        XCTAssertThrowsError(try CLICommand.parse(arguments: base))

        var badCount = base
        badCount[badCount.firstIndex(of: "3")!] = "2"
        badCount.append("--confirm-live")
        XCTAssertThrowsError(try CLICommand.parse(arguments: badCount))

        var badCommit = base
        badCommit[badCommit.firstIndex(of: commit)!] = "abc"
        badCommit.append("--confirm-live")
        XCTAssertThrowsError(try CLICommand.parse(arguments: badCommit))

        var zeroCommit = base
        zeroCommit[zeroCommit.firstIndex(of: commit)!] = String(repeating: "0", count: 40)
        zeroCommit.append("--confirm-live")
        XCTAssertThrowsError(try CLICommand.parse(arguments: zeroCommit))

        var partialVersion = base
        partialVersion[partialVersion.firstIndex(of: "1.0.0")!] = "1.0"
        partialVersion.append("--confirm-live")
        XCTAssertThrowsError(try CLICommand.parse(arguments: partialVersion))

        var credentialImage = base
        credentialImage[credentialImage.firstIndex(of: "python:alpine")!] = "user:password@registry.example/image"
        credentialImage.append("--confirm-live")
        XCTAssertThrowsError(try CLICommand.parse(arguments: credentialImage))
    }

    func testDirectCommandValidationStopsBeforeRuntimeAndFileAccess() throws {
        let tracker = CallTracker()
        let result = try HostwrightCLI.run(
            command: .benchmark(
                options: BenchmarkCLIOptions(
                    image: "python:alpine",
                    sampleCount: 1,
                    reportPath: "/tmp/should-not-exist.json",
                    sourceCommit: commit,
                    sourceDirty: true,
                    expectedContainerVersion: "1.0.0",
                    confirmedLive: false
                )
            ),
            environment: environment(adapter: BenchmarkContractAdapter(), tracker: tracker)
        )
        XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.benchmarkInvalid.rawValue))
        XCTAssertEqual(tracker.fileExistsCalls, 0)
        XCTAssertEqual(tracker.writeCalls, 0)
    }

    func testContractRunWritesBlockedReportWithThreeRawIterationsAndExactCleanup() throws {
        try withTemporaryDirectory { directory in
            let reportURL = directory.appendingPathComponent("benchmark.json")
            let adapter = BenchmarkContractAdapter()
            let result = HostwrightCLI.run(
                arguments: arguments(reportPath: reportURL.path),
                environment: environment(adapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.benchmarkBlocked.rawValue))
            let text = try String(contentsOf: reportURL, encoding: .utf8)
            let report = try BenchmarkLabReportParser.parseReport(text)
            XCTAssertEqual(report.schemaVersion, 2)
            XCTAssertEqual(report.evidence?.evidenceClass, .hardwareBenchmark)
            XCTAssertEqual(report.evidence?.status, .blocked)
            XCTAssertEqual(report.evidence?.cleanup.status, .succeeded)
            XCTAssertEqual(report.environment.appleContainer.version, "1.0.0")
            XCTAssertEqual(report.evidence?.environment.toolVersions["apple-container"], "1.0.0")
            XCTAssertEqual(report.iterations?.count, 3)
            XCTAssertEqual(report.evidence?.cleanup.exactResourceIdentifiers.count, 3)
            XCTAssertEqual(Set(report.iterations?.map(\.resourceIdentifier) ?? []).count, 3)
            XCTAssertTrue(report.observations.contains { $0.dimension == .sleepWake && $0.observation.status == .unmeasured })
            XCTAssertTrue(report.evidence?.blockers.contains { $0.contains("Sleep/wake") } == true)
            XCTAssertTrue(report.evidence?.commands.contains { $0.command.contains("execute delete") } == true)
        }
    }

    func testCleanupFailureProducesFailedEvidenceAndExactIdentifier() throws {
        try withTemporaryDirectory { directory in
            let reportURL = directory.appendingPathComponent("benchmark.json")
            let adapter = BenchmarkContractAdapter(deleteFails: true)
            let result = HostwrightCLI.run(
                arguments: arguments(reportPath: reportURL.path),
                environment: environment(adapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.partialFailure.rawValue)
            let report = try BenchmarkLabReportParser.parseReport(
                String(contentsOf: reportURL, encoding: .utf8)
            )
            XCTAssertEqual(report.evidence?.status, .failed)
            XCTAssertEqual(report.evidence?.cleanup.status, .failed)
            XCTAssertEqual(report.evidence?.cleanup.exactResourceIdentifiers.count, 1)
            XCTAssertTrue(report.evidence?.failures.contains { $0.contains("cleanup") || $0.contains("delete") } == true)
        }
    }

    func testMissingLocalImageCapabilityWritesBlockedReportInsteadOfPass() throws {
        try withTemporaryDirectory { directory in
            let reportURL = directory.appendingPathComponent("benchmark.json")
            let adapter = BenchmarkContractAdapter(createBlocked: true)
            let result = HostwrightCLI.run(
                arguments: arguments(reportPath: reportURL.path),
                environment: environment(adapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            let report = try BenchmarkLabReportParser.parseReport(
                String(contentsOf: reportURL, encoding: .utf8)
            )
            XCTAssertEqual(report.evidence?.status, .blocked)
            XCTAssertEqual(report.iterations?.count, 0)
            XCTAssertTrue(report.evidence?.blockers.contains { $0.contains("Runtime capability unavailable") } == true)
            XCTAssertNotEqual(report.evidence?.status, .passed)
        }
    }

    func testMissingHostIdentityWritesBlockedReportBeforeRuntimeMeasurement() throws {
        try withTemporaryDirectory { directory in
            let reportURL = directory.appendingPathComponent("benchmark.json")
            let host = BenchmarkHostSnapshot(
                operatingSystem: "macOS 26.5",
                operatingSystemBuild: "unavailable",
                architecture: "arm64",
                hardwareModel: "Mac16,8",
                physicalMemoryBytes: 24_000_000_000,
                activeProcessorCount: 12,
                thermalState: .nominal,
                battery: BenchmarkBatterySnapshot(chargePercent: 80, powerSource: "AC Power", isCharging: true)
            )
            let result = HostwrightCLI.run(
                arguments: arguments(reportPath: reportURL.path),
                environment: environment(adapter: BenchmarkContractAdapter(), hostSnapshot: host)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            let report = try BenchmarkLabReportParser.parseReport(String(contentsOf: reportURL, encoding: .utf8))
            XCTAssertEqual(report.evidence?.status, .blocked)
            XCTAssertTrue(report.iterations?.isEmpty == true)
            XCTAssertTrue(report.evidence?.blockers.contains { $0.contains("host identity") } == true)
            XCTAssertFalse(report.evidence?.commands.contains { $0.command.contains("runtimeVersion") } == true)
        }
    }

    func testRuntimeTimeoutReportOmitsPartialOutputAndUnrelatedIdentifiers() throws {
        try withTemporaryDirectory { directory in
            let reportURL = directory.appendingPathComponent("benchmark.json")
            let adapter = BenchmarkContractAdapter(
                versionError: .commandTimedOut(
                    command: "Read Apple container CLI version.",
                    partialOutput: "token=must-not-leak unrelated-resource-name",
                    partialError: "password=must-not-leak"
                )
            )
            let result = HostwrightCLI.run(
                arguments: arguments(reportPath: reportURL.path),
                environment: environment(adapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.partialFailure.rawValue)
            let text = try String(contentsOf: reportURL, encoding: .utf8)
            XCTAssertFalse(text.contains("must-not-leak"))
            XCTAssertFalse(text.contains("unrelated-resource-name"))
            let report = try BenchmarkLabReportParser.parseReport(text)
            XCTAssertEqual(report.evidence?.failures, ["Runtime command timed out: Read Apple container CLI version."])
        }
    }

    func testAttendedSleepWakeContractRecordsGapWithoutClaimingHardwarePass() throws {
        try withTemporaryDirectory { directory in
            let reportURL = directory.appendingPathComponent("benchmark.json")
            let clock = BenchmarkContractClock()
            let tracker = CallTracker()
            var commandArguments = arguments(reportPath: reportURL.path)
            commandArguments.insert(contentsOf: ["--attended-sleep-wake-seconds", "15"], at: commandArguments.count - 1)
            let result = HostwrightCLI.run(
                arguments: commandArguments,
                environment: environment(
                    adapter: BenchmarkContractAdapter(),
                    tracker: tracker,
                    clock: clock,
                    includeBattery: false
                )
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            let report = try BenchmarkLabReportParser.parseReport(String(contentsOf: reportURL, encoding: .utf8))
            XCTAssertEqual(report.evidence?.status, .blocked)
            XCTAssertGreaterThanOrEqual(report.sleepWakeSample?.detectedSleepGapMilliseconds ?? 0, 2_990)
            XCTAssertTrue(report.observations.contains { $0.dimension == .sleepWake && $0.observation.status == .observed })
            XCTAssertTrue(report.evidence?.blockers.contains { $0.contains("Battery") } == true)
            XCTAssertEqual(tracker.notices.count, 2)
            XCTAssertTrue(tracker.notices[0].contains("window open"))
            XCTAssertTrue(tracker.notices[1].contains("window closed"))
        }
    }

    func testExistingReportRefusalPreservesRealFile() throws {
        try withTemporaryDirectory { directory in
            let reportURL = directory.appendingPathComponent("benchmark.json")
            try "sentinel".write(to: reportURL, atomically: true, encoding: .utf8)
            let result = HostwrightCLI.run(
                arguments: arguments(reportPath: reportURL.path),
                environment: environment(adapter: BenchmarkContractAdapter())
            )
            XCTAssertEqual(result.exitCode, CLIExitCode.commandUsage.rawValue)
            XCTAssertEqual(try String(contentsOf: reportURL, encoding: .utf8), "sentinel")
        }
    }

    func testExclusiveReportWriteMapsCreationRaceToOverwriteRefusal() {
        let expected = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        let environment = environment(
            adapter: BenchmarkContractAdapter(),
            writeNewError: expected
        )
        XCTAssertThrowsError(
            try hostwrightWriteNewLocalText(
                path: "/tmp/raced-benchmark.json",
                text: "{}",
                role: "benchmark report",
                environment: environment
            )
        ) { error in
            XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .fileAlreadyExists)
        }
    }

    func testLiveExclusiveWriterCreatesModeSixHundredFileAndRefusesSecondWrite() throws {
        try withTemporaryDirectory { directory in
            let reportURL = directory.appendingPathComponent("exclusive.json")
            try CLIEnvironment.live.writeNewTextFile(reportURL.path, "first")
            XCTAssertEqual(try String(contentsOf: reportURL, encoding: .utf8), "first")
            let attributes = try FileManager.default.attributesOfItem(atPath: reportURL.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
            XCTAssertThrowsError(try CLIEnvironment.live.writeNewTextFile(reportURL.path, "second"))
            XCTAssertEqual(try String(contentsOf: reportURL, encoding: .utf8), "first")
        }
    }

    private func arguments(reportPath: String) -> [String] {
        [
            "benchmark",
            "--image", "docker.io/library/python:alpine",
            "--samples", "3",
            "--report", reportPath,
            "--source-commit", commit,
            "--source-dirty", "true",
            "--expected-container-version", "1.0.0",
            "--confirm-live"
        ]
    }

    private func environment(
        adapter: any RuntimeAdapter,
        tracker: CallTracker = CallTracker(),
        clock: BenchmarkContractClock? = nil,
        includeBattery: Bool = true,
        hostSnapshot: BenchmarkHostSnapshot? = nil,
        writeNewError: Error? = nil
    ) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: { path in
                tracker.fileExistsCalls += 1
                return FileManager.default.fileExists(atPath: path)
            },
            readTextFile: { try String(contentsOfFile: $0, encoding: .utf8) },
            writeTextFile: { path, text in
                tracker.writeCalls += 1
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            },
            writeNewTextFile: { path, text in
                if let writeNewError {
                    throw writeNewError
                }
                tracker.writeCalls += 1
                try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            },
            executablePath: { name in name == "container" ? "/usr/local/bin/container" : "/usr/bin/\(name)" },
            runtimeAdapter: { adapter },
            swiftVersion: { "Swift 6.3.3" },
            platformSnapshot: { PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64") },
            operatingSystemDescription: { "macOS 26.5" },
            benchmarkHostSnapshot: {
                hostSnapshot ?? BenchmarkHostSnapshot(
                    operatingSystem: "macOS 26.5",
                    operatingSystemBuild: "25F90",
                    architecture: "arm64",
                    hardwareModel: "Mac16,8",
                    physicalMemoryBytes: 24_000_000_000,
                    activeProcessorCount: 12,
                    thermalState: .nominal,
                    battery: includeBattery
                        ? BenchmarkBatterySnapshot(chargePercent: 80, powerSource: "AC Power", isCharging: true)
                        : nil
                )
            },
            benchmarkDate: { clock?.date() ?? Date(timeIntervalSince1970: 1_789_000_000) },
            benchmarkMonotonicNanoseconds: { clock?.uptimeNanoseconds() ?? DispatchTime.now().uptimeNanoseconds },
            benchmarkSleep: { seconds in clock?.sleep(seconds: seconds) },
            benchmarkUUID: { UUID() },
            benchmarkNotice: { tracker.notices.append($0) }
        )
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-benchmark-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class BenchmarkContractClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallSeconds: TimeInterval = 1_789_000_000
    private var uptime: UInt64 = 1_000_000_000

    func date() -> Date {
        lock.withLock { Date(timeIntervalSince1970: wallSeconds) }
    }

    func uptimeNanoseconds() -> UInt64 {
        lock.withLock {
            defer { uptime += 1_000_000 }
            return uptime
        }
    }

    func sleep(seconds: TimeInterval) {
        lock.withLock {
            wallSeconds += seconds
            uptime += UInt64(seconds * 1_000_000_000)
            if seconds >= 15 {
                wallSeconds += 3
            }
        }
    }
}

private final class CallTracker: @unchecked Sendable {
    var fileExistsCalls = 0
    var writeCalls = 0
    var notices: [String] = []
}

private actor BenchmarkContractAdapter: RuntimeAdapter {
    private struct Entry {
        let service: DesiredRuntimeService
        var state: RuntimeLifecycleState
    }

    private var entries: [String: Entry] = [:]
    private let createBlocked: Bool
    private let deleteFails: Bool
    private let versionError: RuntimeAdapterError?
    private static let capabilitySnapshot = RuntimeCapabilitySnapshot(
        descriptor: RuntimeProviderDescriptor(
            providerID: .appleContainerCLI,
            components: [
                RuntimeProviderComponent(
                    identifier: .appleContainerCLI,
                    version: "1.1.0",
                    build: "109",
                    fingerprint: "099d8db0"
                ),
                RuntimeProviderComponent(
                    identifier: .appleContainerAPIService,
                    version: "1.1.0",
                    build: "109",
                    fingerprint: "099d8db0"
                )
            ],
            minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
            supportedArchitectures: [.arm64]
        ),
        host: RuntimeProviderHostPlatform(
            macOSVersion: RuntimeProviderMacOSVersion(major: 26, minor: 5, patch: 0),
            macOSBuild: "25F90",
            architecture: .arm64
        ),
        features: RuntimeProviderCapabilityProbe.appleContainerCLIFeatures
    )

    init(
        createBlocked: Bool = false,
        deleteFails: Bool = false,
        versionError: RuntimeAdapterError? = nil
    ) {
        self.createBlocked = createBlocked
        self.deleteFails = deleteFails
        self.versionError = versionError
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "BenchmarkContractAdapter",
            adapterVersion: "unit-contract",
            runtimeName: "scripted-contract-runtime",
            runtimeVersion: "1.0.0",
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation, .cleanup]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation, .cleanup]
    }

    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        Self.capabilitySnapshot
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        let services = desiredState.services.compactMap { desired -> ObservedRuntimeService? in
            guard let entry = entries[desired.identity.managedResourceIdentifier] else { return nil }
            return ObservedRuntimeService(
                identity: entry.service.identity,
                resourceIdentifier: entry.service.identity.managedResourceIdentifier,
                image: entry.service.image,
                lifecycleState: entry.state
            )
        }
        return ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: services,
            adapterMetadata: await metadata(),
            capabilitySHA256: Self.capabilitySnapshot.canonicalSHA256
        )
    }

    func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
        RuntimePlan(actions: desiredState.services.map { service in
            PlannedRuntimeAction(
                kind: .create,
                identity: service.identity,
                resourceIdentifier: service.identity.managedResourceIdentifier,
                isDestructive: false,
                summary: "Create contract benchmark resource.",
                desiredService: service
            )
        })
    }

    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func runtimeVersion() async throws -> String {
        if let versionError {
            throw versionError
        }
        return "1.0.0"
    }

    func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot {
        guard var entry = entries[resourceIdentifier], entry.state == .running else {
            throw RuntimeAdapterError.outputParseFailed("contract resource was not running")
        }
        entry.state = .exited
        entries[resourceIdentifier] = entry
        return RuntimeResourceUsageSnapshot(
            resourceIdentifier: resourceIdentifier,
            cpuUsageMicroseconds: 100,
            memoryUsageBytes: 2_000_000,
            memoryLimitBytes: 1_073_741_824,
            networkReceiveBytes: 10,
            networkTransmitBytes: 20,
            blockReadBytes: 30,
            blockWriteBytes: 40,
            processCount: 1
        )
    }

    func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        RuntimeLocalImageEvidence(
            reference: imageReference,
            descriptorDigest: "sha256:" + String(repeating: "a", count: 64),
            variantDigest: "sha256:" + String(repeating: "b", count: 64),
            architecture: "arm64",
            operatingSystem: "linux"
        )
    }

    func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
        guard confirmation?.confirmed == true, confirmation?.planHash?.isEmpty == false else {
            throw RuntimeAdapterError.commandRejected(classification: .mutating, message: "confirmation required")
        }
        switch action.kind {
        case .create:
            if createBlocked {
                throw RuntimeAdapterError.capabilityUnavailable(.lifecycleMutation)
            }
            guard let service = action.desiredService else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy("missing desired service")
            }
            entries[action.resourceIdentifier] = Entry(service: service, state: .created)
        case .start:
            guard var entry = entries[action.resourceIdentifier] else {
                throw RuntimeAdapterError.outputParseFailed("missing resource")
            }
            entry.state = .running
            entries[action.resourceIdentifier] = entry
        case .remove:
            if deleteFails {
                throw RuntimeAdapterError.commandFailed(exitStatus: 1, message: "exact delete failed", standardError: "delete failed")
            }
            entries.removeValue(forKey: action.resourceIdentifier)
        case .update, .stop, .restart, .noOp:
            throw RuntimeAdapterError.mutationUnavailableByPolicy("unsupported contract action")
        }
        return RuntimeEvent(identity: action.identity, message: "contract action", resourceIdentifier: action.resourceIdentifier)
    }
}
