import Foundation
import HostwrightCore
import HostwrightHealth
import HostwrightRuntime

final class BenchmarkSession: @unchecked Sendable {
    private static let workloadSeconds = 3
    private static let pollIntervalSeconds = 0.1
    private static let cleanupQuiescenceSeconds = 1.0
    private static let maximumPollAttempts = 150

    private let options: BenchmarkCLIOptions
    private let environment: CLIEnvironment
    private let adapter: any RuntimeAdapter
    private let redactionPolicy = RuntimeRedactionPolicy.default

    private var commands: [HostwrightEvidenceCommand] = []
    private var iterations: [BenchmarkIterationReport] = []
    private var cleanupCandidates: [DesiredRuntimeService] = []
    private var cleanedIdentifiers: Set<String> = []
    private var cleanupFailures: [String] = []
    private var failures: [String] = []
    private var blockers: [String] = []
    private var actualContainerVersion: String?
    private var adapterMetadata: RuntimeAdapterMetadata?
    private var runtimeCapabilitySHA256: String?
    private var imageEvidence: RuntimeLocalImageEvidence?
    private var versionMatchesExpected = false
    private var sleepWakeSample: BenchmarkSleepWakeSample?

    init(options: BenchmarkCLIOptions, environment: CLIEnvironment) {
        self.options = options
        self.environment = environment
        self.adapter = environment.runtimeAdapter()
    }

    func execute() -> BenchmarkLabReport {
        let before = environment.benchmarkHostSnapshot()
        if runPreflight(host: before) {
            runIterations()
        }
        cleanupRemainingCandidates()

        let after = environment.benchmarkHostSnapshot()
        let observations = makeObservations(before: before, after: after)
        let status: HostwrightEvidenceStatus
        if !failures.isEmpty || !cleanupFailures.isEmpty {
            status = .failed
        } else if !blockers.isEmpty {
            status = .blocked
        } else {
            status = .passed
        }

        let observedCount = observations.filter { $0.observation.status == .observed }.count
        let blockedCount = observations.count - observedCount
        let failedCount = status == .failed ? 1 : 0
        let cleanup = cleanupReport()
        var toolVersions = [
            "hostwright": HostwrightIdentity.version,
            "apple-container": actualContainerVersion ?? "unavailable",
            "runtime-adapter": adapterMetadata.map { "\($0.adapterName) \($0.adapterVersion)" } ?? "unavailable",
            "image-descriptor": imageEvidence?.descriptorDigest ?? "unavailable",
            "swift": environment.swiftVersion() ?? "unavailable"
        ]
        toolVersions = toolVersions.mapValues { $0.isEmpty ? "unavailable" : $0 }
        let evidence = HostwrightEvidenceReport(
            evidenceClass: .hardwareBenchmark,
            status: status,
            recordedAt: timestamp(environment.benchmarkDate()),
            source: HostwrightEvidenceSource(commit: options.sourceCommit, dirty: options.sourceDirty),
            environment: HostwrightEvidenceEnvironment(
                operatingSystem: before.operatingSystem,
                build: before.operatingSystemBuild,
                architecture: before.architecture,
                hardwareModel: before.hardwareModel,
                memoryBytes: before.physicalMemoryBytes,
                toolVersions: toolVersions
            ),
            commands: commands,
            rawResults: HostwrightEvidenceCounts(
                executed: observedCount + blockedCount + failedCount,
                passed: observedCount,
                failed: failedCount,
                blocked: blockedCount
            ),
            failures: (failures + cleanupFailures).map(redactionPolicy.redact),
            blockers: blockers.map(redactionPolicy.redact),
            cleanup: cleanup
        )

        return BenchmarkLabReport(
            schemaVersion: 2,
            profileID: "phase36-live-\(options.sampleCount)-samples",
            recordedAt: evidence.recordedAt,
            environment: benchmarkEnvironment(host: before),
            resourcePolicy: .confirmedLive,
            observations: observations,
            limits: [
                "Measurements describe only this commit, host, image, and recorded run.",
                "No production density or capacity guarantee.",
                "No image pull, broad cleanup, state write, or telemetry upload.",
                "No GPU, ANE, Metal, Core ML, or MLX claim."
            ],
            evidence: evidence,
            iterations: iterations,
            protocols: [
                BenchmarkProtocolRecord(
                    identifier: "bounded-container-v1",
                    status: iterations.count == options.sampleCount ? .observed : .unmeasured,
                    method: "RuntimeAdapter create/start/observe/stats/natural-exit/exact-delete",
                    note: "Each sample uses a unique versioned Hostwright identity and a bounded sleep process."
                ),
                BenchmarkProtocolRecord(
                    identifier: "sleep-wake-resume-v1",
                    status: sleepWakeWasObserved ? .observed : .unmeasured,
                    method: "attended wall-clock versus monotonic-uptime gap plus exact post-wake RuntimeAdapter observation",
                    note: sleepWakeWasObserved
                        ? "An attended sleep interval was detected and the exact benchmark resource was observed after wake."
                        : "No qualifying attended sleep interval was detected; this protocol remains blocked."
                )
            ],
            sleepWakeSample: sleepWakeSample,
            image: benchmarkImageReport
        )
    }

    private func runPreflight(host: BenchmarkHostSnapshot) -> Bool {
        do {
            let (metadata, _) = try timed("RuntimeAdapter.metadata") {
                await self.adapter.metadata()
            }
            adapterMetadata = metadata
            guard metadata.supportsMutation,
                  !metadata.adapterName.isEmpty,
                  !metadata.adapterVersion.isEmpty else {
                blockers.append("Runtime adapter metadata does not authorize benchmark mutation.")
                return false
            }

            let (capabilities, _) = try timed("RuntimeAdapter.capabilities") {
                try await self.adapter.capabilities()
            }
            let required: Set<RuntimeCapability> = [.readOnlyObservation, .lifecycleMutation, .cleanup]
            guard required.isSubset(of: Set(capabilities)) else {
                blockers.append("Runtime adapter is missing required read, lifecycle, or cleanup capabilities.")
                return false
            }
        } catch {
            register(error)
            return false
        }

        let unavailableHostValues = [
            host.operatingSystem,
            host.operatingSystemBuild,
            host.architecture,
            host.hardwareModel
        ].contains { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty || normalized == "unknown" || normalized == "unavailable"
        }
        guard !unavailableHostValues,
              host.physicalMemoryBytes > 0,
              host.activeProcessorCount > 0 else {
            blockers.append("Required host identity or hardware facts are unavailable; hardware measurement did not start.")
            return false
        }

        actualContainerVersion = runVersionProbe()
        guard actualContainerVersion != nil, versionMatchesExpected else {
            return false
        }
        imageEvidence = runImageProbe()
        guard let imageEvidence else {
            return false
        }
        guard imageEvidence.architecture == host.architecture else {
            blockers.append(
                "Local image architecture \(imageEvidence.architecture) does not match benchmark host architecture \(host.architecture)."
            )
            return false
        }
        guard imageEvidence.operatingSystem == "linux" else {
            blockers.append("Local image operating system \(imageEvidence.operatingSystem) is unsupported for this benchmark.")
            return false
        }
        return true
    }

    private func runVersionProbe() -> String? {
        do {
            let (version, _) = try timed("RuntimeAdapter.runtimeVersion") {
                try await self.adapter.runtimeVersion()
            }
            guard let observedVersion = AppleContainerVersionParser.parse(version) else {
                failures.append("Apple container version output did not contain a parseable semantic version.")
                return nil
            }
            if observedVersion != options.expectedContainerVersion {
                failures.append(
                    "Apple container version drift: expected \(options.expectedContainerVersion), observed \(observedVersion)."
                )
                return observedVersion
            }
            versionMatchesExpected = true
            return observedVersion
        } catch {
            register(error)
            return nil
        }
    }

    private func runImageProbe() -> RuntimeLocalImageEvidence? {
        do {
            let (evidence, _) = try timed("RuntimeAdapter.localImageEvidence \(options.image)") {
                try await self.adapter.localImageEvidence(for: self.options.image)
            }
            return evidence
        } catch {
            register(error)
            return nil
        }
    }

    private func runIterations() {
        for sequence in 1...options.sampleCount {
            do {
                try runIteration(sequence: sequence)
            } catch {
                register(error)
                return
            }
        }
    }

    private func runIteration(sequence: Int) throws {
        let instance = environment.benchmarkUUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let identity = RuntimeServiceIdentity(projectName: "bench", serviceName: "probe", instanceName: instance)
        let service = DesiredRuntimeService(
            identity: identity,
            image: options.image,
            command: ["sleep", String(workloadSeconds(sequence: sequence))]
        )
        let desired = DesiredRuntimeState(projectName: identity.projectName, services: [service])
        let identifier = identity.managedResourceIdentifier
        guard identifier.hasPrefix(BenchmarkResourcePolicy.confirmedLive.disposableResourceNamePrefix) else {
            throw BenchmarkSessionError.invalidIdentity(identifier)
        }

        let (initialObservation, _) = try timed("RuntimeAdapter.observe preflight \(identifier)") {
            try await self.adapter.observe(desiredState: desired)
        }
        guard let observedCapabilitySHA256 = initialObservation.capabilitySHA256,
              observedCapabilitySHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil else {
            throw BenchmarkSessionError.capabilityUnavailable(identifier)
        }
        guard let providerID = adapterMetadata?.providerID else {
            throw BenchmarkSessionError.capabilityUnavailable(identifier)
        }
        if let runtimeCapabilitySHA256,
           runtimeCapabilitySHA256 != observedCapabilitySHA256 {
            throw BenchmarkSessionError.capabilityChanged(identifier)
        }
        runtimeCapabilitySHA256 = observedCapabilitySHA256
        guard initialObservation.services.isEmpty else {
            throw BenchmarkSessionError.resourceCollision(identifier)
        }

        let (plan, _) = try timed("RuntimeAdapter.plan create \(identifier)") {
            try await self.adapter.plan(desiredState: desired, observedState: initialObservation)
        }
        guard plan.actions.count == 1,
              let createAction = plan.actions.first,
              createAction.kind == .create,
              createAction.identity == identity,
              createAction.resourceIdentifier == identifier else {
            throw BenchmarkSessionError.invalidPlan(identifier)
        }

        cleanupCandidates.append(service)
        let confirmation = RuntimeMutationConfirmation(
            confirmed: true,
            reason: "Confirmed disposable Phase 36 hardware benchmark resource.",
            planHash: hostwrightStableHash("phase36|\(options.sourceCommit)|\(identifier)"),
            context: RuntimeMutationContext(
                providerID: providerID,
                capabilitySHA256: observedCapabilitySHA256,
                operationID: "benchmark-iteration-\(sequence)-\(instance)",
                resourceUUID: HostwrightResourceUUID.legacy(kind: "benchmark-resource", identifier: identifier),
                resourceGeneration: 1,
                projectResourceUUID: HostwrightResourceUUID.legacy(kind: "project", identifier: "project-bench"),
                projectGeneration: 1,
                providerGeneration: 1,
                fencingToken: HostwrightResourceUUID.generate()
            )
        )
        let (_, createDuration) = try timed("RuntimeAdapter.execute create \(identifier)") {
            try await self.adapter.execute(createAction, confirmation: confirmation)
        }

        let startAction = PlannedRuntimeAction(
            kind: .start,
            identity: identity,
            resourceIdentifier: identifier,
            isDestructive: false,
            summary: "Start disposable benchmark resource.",
            desiredService: service
        )
        let bootStart = environment.benchmarkMonotonicNanoseconds()
        let (_, startDuration) = try timed("RuntimeAdapter.execute start \(identifier)") {
            try await self.adapter.execute(startAction, confirmation: confirmation)
        }

        var runningService: ObservedRuntimeService?
        var pollDurations: [Int] = []
        for _ in 0..<Self.maximumPollAttempts {
            let (observation, duration) = try timed("RuntimeAdapter.observe boot \(identifier)") {
                try await self.adapter.observe(desiredState: desired)
            }
            pollDurations.append(duration)
            if let service = observation.services.first(where: { $0.resourceIdentifier == identifier }),
               service.identity == identity,
               service.lifecycleState == .running {
                runningService = service
                break
            }
            environment.benchmarkSleep(Self.pollIntervalSeconds)
        }
        guard runningService != nil else {
            throw BenchmarkSessionError.bootTimedOut(identifier)
        }
        let bootDuration = milliseconds(since: bootStart)

        let (usage, _) = try timed("RuntimeAdapter.resourceUsage \(identifier)") {
            try await self.adapter.resourceUsage(for: identifier)
        }
        guard usage.resourceIdentifier == identifier else {
            throw BenchmarkSessionError.statsIdentityMismatch(identifier)
        }
        let hostSample = environment.benchmarkHostSnapshot()
        iterations.append(
            BenchmarkIterationReport(
                sequence: sequence,
                resourceIdentifier: identifier,
                createDurationMilliseconds: createDuration,
                startDurationMilliseconds: startDuration,
                bootLatencyMilliseconds: bootDuration,
                observationPollDurationsMilliseconds: pollDurations,
                resourceUsage: BenchmarkResourceUsageSample(
                    cpuUsageMicroseconds: usage.cpuUsageMicroseconds,
                    memoryUsageBytes: usage.memoryUsageBytes,
                    memoryLimitBytes: usage.memoryLimitBytes,
                    networkReceiveBytes: usage.networkReceiveBytes,
                    networkTransmitBytes: usage.networkTransmitBytes,
                    blockReadBytes: usage.blockReadBytes,
                    blockWriteBytes: usage.blockWriteBytes,
                    processCount: usage.processCount
                ),
                thermalState: hostSample.thermalState,
                batteryChargePercent: hostSample.battery?.chargePercent
            )
        )

        if sequence == 1, let attendedSeconds = options.attendedSleepWakeSeconds {
            try runAttendedSleepWake(
                seconds: attendedSeconds,
                desired: desired,
                identity: identity,
                identifier: identifier
            )
        }

        try cleanup(service: service, confirmation: confirmation)
    }

    private func runAttendedSleepWake(
        seconds: Int,
        desired: DesiredRuntimeState,
        identity: RuntimeServiceIdentity,
        identifier: String
    ) throws {
        environment.benchmarkNotice(
            "HW-BENCH: attended sleep/wake window open for \(seconds) seconds; put the Mac to sleep now."
        )
        let beforeDate = environment.benchmarkDate()
        let beforeUptime = environment.benchmarkMonotonicNanoseconds()
        environment.benchmarkSleep(TimeInterval(seconds))
        let afterDate = environment.benchmarkDate()
        let afterUptime = environment.benchmarkMonotonicNanoseconds()
        environment.benchmarkNotice("HW-BENCH: attended window closed; verifying exact post-wake runtime identity.")

        let (observation, _) = try timed("RuntimeAdapter.observe post-wake \(identifier)") {
            try await self.adapter.observe(desiredState: desired)
        }
        guard let service = observation.services.first(where: { $0.resourceIdentifier == identifier }),
              service.identity == identity else {
            throw BenchmarkSessionError.postWakeObservationMissing(identifier)
        }

        let wallMilliseconds = max(0, Int(afterDate.timeIntervalSince(beforeDate) * 1_000))
        let uptimeMilliseconds = afterUptime >= beforeUptime
            ? Int(clamping: (afterUptime - beforeUptime) / 1_000_000)
            : 0
        sleepWakeSample = BenchmarkSleepWakeSample(
            requestedWindowSeconds: seconds,
            beforeTimestamp: timestamp(beforeDate),
            afterTimestamp: timestamp(afterDate),
            wallElapsedMilliseconds: wallMilliseconds,
            uptimeElapsedMilliseconds: uptimeMilliseconds,
            detectedSleepGapMilliseconds: max(0, wallMilliseconds - uptimeMilliseconds),
            postWakeLifecycleState: service.lifecycleState.rawValue
        )
    }

    private func cleanupRemainingCandidates() {
        for service in cleanupCandidates where !cleanedIdentifiers.contains(service.identity.managedResourceIdentifier) {
            guard let providerID = adapterMetadata?.providerID,
                  let capabilitySHA256 = runtimeCapabilitySHA256,
                  capabilitySHA256.range(
                      of: "^[a-f0-9]{64}$",
                      options: .regularExpression
                  ) != nil else {
                cleanupFailures.append(
                    "Exact cleanup could not bind the provider capability context for \(service.identity.managedResourceIdentifier)."
                )
                continue
            }
            let confirmation = RuntimeMutationConfirmation(
                confirmed: true,
                reason: "Exact cleanup for disposable Phase 36 hardware benchmark resource.",
                planHash: hostwrightStableHash("phase36-cleanup|\(options.sourceCommit)|\(service.identity.managedResourceIdentifier)"),
                context: RuntimeMutationContext(
                    providerID: providerID,
                    capabilitySHA256: capabilitySHA256,
                    operationID: "benchmark-cleanup-\(service.identity.instanceName ?? "resource")",
                    resourceUUID: HostwrightResourceUUID.legacy(
                        kind: "benchmark-resource",
                        identifier: service.identity.managedResourceIdentifier
                    ),
                    resourceGeneration: 1,
                    projectResourceUUID: HostwrightResourceUUID.legacy(kind: "project", identifier: "project-bench"),
                    projectGeneration: 1,
                    providerGeneration: 1,
                    fencingToken: HostwrightResourceUUID.generate()
                )
            )
            do {
                try cleanup(service: service, confirmation: confirmation)
            } catch {
                cleanupFailures.append(
                    "Exact cleanup failed for \(service.identity.managedResourceIdentifier): \(safeErrorMessage(error))"
                )
            }
        }
    }

    private func cleanup(service: DesiredRuntimeService, confirmation: RuntimeMutationConfirmation) throws {
        let desired = DesiredRuntimeState(projectName: service.identity.projectName, services: [service])
        let identifier = service.identity.managedResourceIdentifier
        var observedService: ObservedRuntimeService?
        var terminalObservationCount = 0

        for _ in 0..<Self.maximumPollAttempts {
            let (observation, _) = try timed("RuntimeAdapter.observe cleanup \(identifier)") {
                try await self.adapter.observe(desiredState: desired)
            }
            guard let current = observation.services.first(where: { $0.resourceIdentifier == identifier }) else {
                cleanedIdentifiers.insert(identifier)
                return
            }
            guard current.identity == service.identity else {
                throw BenchmarkSessionError.ownershipMismatch(identifier)
            }
            observedService = current
            if current.lifecycleState == .created || current.lifecycleState == .stopped || current.lifecycleState == .exited {
                terminalObservationCount += 1
                if terminalObservationCount >= 2 {
                    break
                }
                environment.benchmarkSleep(Self.cleanupQuiescenceSeconds)
                continue
            }
            terminalObservationCount = 0
            environment.benchmarkSleep(Self.pollIntervalSeconds)
        }

        guard let observedService,
              observedService.lifecycleState == .created ||
                observedService.lifecycleState == .stopped ||
                observedService.lifecycleState == .exited else {
            throw BenchmarkSessionError.cleanupTimedOut(identifier)
        }
        let remove = PlannedRuntimeAction(
            kind: .remove,
            identity: service.identity,
            resourceIdentifier: identifier,
            isDestructive: true,
            summary: "Delete exact disposable benchmark resource."
        )
        _ = try timed("RuntimeAdapter.execute delete \(identifier)") {
            try await self.adapter.execute(remove, confirmation: confirmation)
        }
        let (after, _) = try timed("RuntimeAdapter.observe cleanup verification \(identifier)") {
            try await self.adapter.observe(desiredState: desired)
        }
        guard after.services.allSatisfy({ $0.resourceIdentifier != identifier }) else {
            throw BenchmarkSessionError.cleanupVerificationFailed(identifier)
        }
        cleanedIdentifiers.insert(identifier)
    }

    private func makeObservations(before: BenchmarkHostSnapshot, after: BenchmarkHostSnapshot) -> [BenchmarkObservation] {
        let memoryValues = iterations.map { Int(clamping: $0.resourceUsage.memoryUsageBytes) }
        let bootValues = iterations.map(\.bootLatencyMilliseconds)
        let pollingValues = iterations.flatMap(\.observationPollDurationsMilliseconds)
        let battery: ResourceObservation
        if let initial = before.battery, let final = after.battery {
            battery = ResourceObservation(
                status: .observed,
                value: String(format: "%.3f -> %.3f", initial.chargePercent, final.chargePercent),
                unit: "percent",
                method: .liveHardwareBenchmark,
                note: "Battery charge and power-source facts were read before and after the bounded run; this short sample is not an efficiency claim."
            )
        } else {
            battery = ResourceObservation(
                status: .unavailable,
                value: nil,
                unit: nil,
                method: .liveHardwareBenchmark,
                note: "No battery power source was available from IOKit for this host."
            )
            blockers.append("Battery evidence is unavailable on this host.")
        }

        let thermalStatus: ResourceObservationStatus = before.thermalState == .unknown || after.thermalState == .unknown
            ? .unavailable
            : .observed
        if thermalStatus == .unavailable {
            blockers.append("Thermal-state evidence is unavailable on this host.")
        }
        if !sleepWakeWasObserved {
            blockers.append("Sleep/wake evidence was not observed; the attended resume protocol remains blocked.")
        }

        return [
            BenchmarkObservation(
                dimension: .memoryPressure,
                observation: aggregateObservation(
                    values: memoryValues,
                    unit: "bytes",
                    note: "Median Apple container memoryUsageBytes across raw iteration samples; not a host capacity guarantee."
                )
            ),
            BenchmarkObservation(
                dimension: .bootLatency,
                observation: aggregateObservation(
                    values: bootValues,
                    unit: "milliseconds",
                    note: "Median elapsed time from confirmed start invocation to the first exact running observation."
                )
            ),
            BenchmarkObservation(
                dimension: .pollingOverhead,
                observation: aggregateObservation(
                    values: pollingValues,
                    unit: "milliseconds",
                    note: "Median wall-clock duration of exact RuntimeAdapter observation calls during boot polling."
                )
            ),
            BenchmarkObservation(dimension: .battery, observation: battery),
            BenchmarkObservation(
                dimension: .thermal,
                observation: ResourceObservation(
                    status: thermalStatus,
                    value: thermalStatus == .observed ? "\(before.thermalState.rawValue) -> \(after.thermalState.rawValue)" : nil,
                    unit: nil,
                    method: .liveHardwareBenchmark,
                    note: "ProcessInfo thermal state before and after the bounded run; not a sustained thermal test."
                )
            ),
            BenchmarkObservation(
                dimension: .sleepWake,
                observation: sleepWakeObservation
            ),
            BenchmarkObservation(
                dimension: .appleContainerVersionDrift,
                observation: ResourceObservation(
                    status: actualContainerVersion == nil ? .unavailable : .observed,
                    value: actualContainerVersion.map { "expected=\(options.expectedContainerVersion); observed=\($0)" },
                    unit: nil,
                    method: .liveHardwareBenchmark,
                    note: "Exact local Apple container version output was compared with the operator-supplied expected version."
                )
            )
        ]
    }

    private var sleepWakeWasObserved: Bool {
        (sleepWakeSample?.detectedSleepGapMilliseconds ?? 0) >= 2_000
    }

    private var sleepWakeObservation: ResourceObservation {
        guard let sample = sleepWakeSample, sleepWakeWasObserved else {
            return .unmeasured(
                method: .liveHardwareBenchmark,
                note: "Use --attended-sleep-wake-seconds and put the host to sleep during that window; no system sleep is forced."
            )
        }
        return ResourceObservation(
            status: .observed,
            value: String(sample.detectedSleepGapMilliseconds),
            unit: "milliseconds",
            method: .liveHardwareBenchmark,
            note: "Wall time exceeded monotonic uptime and the exact resource was observed after wake."
        )
    }

    private func workloadSeconds(sequence: Int) -> Int {
        if sequence == 1, let attended = options.attendedSleepWakeSeconds {
            return attended + 10
        }
        return Self.workloadSeconds
    }

    private func aggregateObservation(values: [Int], unit: String, note: String) -> ResourceObservation {
        guard let value = median(values) else {
            return .unmeasured(method: .liveHardwareBenchmark, note: note)
        }
        return ResourceObservation(
            status: .observed,
            value: String(value),
            unit: unit,
            method: .liveHardwareBenchmark,
            note: note
        )
    }

    private func benchmarkEnvironment(host: BenchmarkHostSnapshot) -> BenchmarkEnvironmentReport {
        BenchmarkEnvironmentReport(
            hardware: ResourceHardwareReport(
                architecture: host.architecture,
                activeProcessorCount: host.activeProcessorCount,
                physicalMemoryBytes: host.physicalMemoryBytes,
                unifiedMemoryNote: "Physical unified-memory total is recorded as environment context, not workload capacity."
            ),
            operatingSystem: ResourceOperatingSystemReport(
                description: host.operatingSystem,
                macOSMajorVersion: PlatformSnapshot.current.macOSMajorVersion
            ),
            appleContainer: ResourceAppleContainerReport(
                executablePath: environment.executablePath("container"),
                version: actualContainerVersion,
                versionObservation: ResourceObservation(
                    status: actualContainerVersion == nil ? .unavailable : .observed,
                    value: actualContainerVersion,
                    unit: nil,
                    method: .liveHardwareBenchmark,
                    note: "Version was read through RuntimeAdapter during this run."
                )
            ),
            workloadProfile: .localContainersGeneral
        )
    }

    private var benchmarkImageReport: BenchmarkImageReport {
        guard let imageEvidence else {
            return BenchmarkImageReport(
                requestedReference: options.image,
                descriptorDigest: nil,
                variantDigest: nil,
                architecture: nil,
                operatingSystem: nil,
                status: .unavailable,
                note: "The requested image was not resolved from the local Apple container image inventory; no pull was attempted."
            )
        }
        return BenchmarkImageReport(
            requestedReference: imageEvidence.reference,
            descriptorDigest: imageEvidence.descriptorDigest,
            variantDigest: imageEvidence.variantDigest,
            architecture: imageEvidence.architecture,
            operatingSystem: imageEvidence.operatingSystem,
            status: .observed,
            note: "Reference, descriptor digest, platform variant digest, architecture, and OS came from the local Apple container image inventory."
        )
    }

    private func cleanupReport() -> HostwrightEvidenceCleanup {
        let identifiers = cleanupCandidates.map { $0.identity.managedResourceIdentifier }
        if identifiers.isEmpty {
            return HostwrightEvidenceCleanup(
                status: .notRequired,
                exactResourceIdentifiers: [],
                message: "No runtime resource was created before the run blocked or failed."
            )
        }
        if cleanupFailures.isEmpty && identifiers.allSatisfy(cleanedIdentifiers.contains) {
            return HostwrightEvidenceCleanup(
                status: .succeeded,
                exactResourceIdentifiers: identifiers,
                message: "Every exact benchmark identifier was verified absent after cleanup."
            )
        }
        return HostwrightEvidenceCleanup(
            status: .failed,
            exactResourceIdentifiers: identifiers,
            message: redactionPolicy.redact(cleanupFailures.joined(separator: " "))
        )
    }

    private func timed<T: Sendable>(
        _ command: String,
        operation: @escaping @Sendable () async throws -> T
    ) throws -> (T, Int) {
        let start = environment.benchmarkMonotonicNanoseconds()
        do {
            let value = try hostwrightWaitForAsync(operation)
            let duration = milliseconds(since: start)
            commands.append(HostwrightEvidenceCommand(command: command, exitCode: 0, durationMilliseconds: duration))
            return (value, duration)
        } catch {
            let duration = milliseconds(since: start)
            commands.append(HostwrightEvidenceCommand(command: command, exitCode: 1, durationMilliseconds: duration))
            throw error
        }
    }

    private func register(_ error: Error) {
        let message = safeErrorMessage(error)
        if let sessionError = error as? BenchmarkSessionError {
            switch sessionError {
            case .resourceCollision:
                blockers.append(message)
            default:
                failures.append(message)
            }
            return
        }
        if let runtimeError = error as? RuntimeAdapterError {
            switch runtimeError {
            case .runtimeUnavailable, .executableNotFound, .unsupportedRuntime, .capabilityUnavailable:
                blockers.append(message)
            case .normalizedFailure(let failure)
                where failure.category == .unavailable || failure.category == .incompatible:
                blockers.append(message)
            default:
                failures.append(message)
            }
            return
        }
        failures.append(message)
    }

    private func safeErrorMessage(_ error: Error) -> String {
        if let sessionError = error as? BenchmarkSessionError {
            return redactionPolicy.redact(sessionError.description)
        }
        guard let runtimeError = error as? RuntimeAdapterError else {
            return "Unexpected benchmark operation failure."
        }
        switch runtimeError.redacted(using: redactionPolicy) {
        case .runtimeUnavailable(let message):
            return "Runtime unavailable: \(message)"
        case .executableNotFound:
            return "Runtime executable was not found."
        case .unsupportedRuntime(let message):
            return "Unsupported runtime: \(message)"
        case .commandRejected(let classification, let message):
            return "Runtime command was rejected (\(classification.rawValue)): \(message)"
        case .commandTimedOut(let command, _, _):
            return "Runtime command timed out: \(command)"
        case .commandCancelled(let command, _, _):
            return "Runtime command was cancelled: \(command)"
        case .commandOutputLimitExceeded(let command, _, _):
            return "Runtime command exceeded its output limit: \(command)"
        case .commandProcessTreeViolation(let command, _, _):
            return "Runtime command left an unexpected process tree: \(command)"
        case .commandFailed(let exitStatus, let message, _):
            return "Runtime command failed with exit \(exitStatus): \(message)"
        case .managedRestartStartFailedAfterStop(let message, _):
            return "Runtime restart failed after stop: \(message)"
        case .outputParseFailed(let message):
            return "Runtime output parsing failed: \(message)"
        case .permissionDenied(let message):
            return "Runtime permission denied: \(message)"
        case .redactionFailure:
            return "Runtime output could not be safely redacted."
        case .capabilityUnavailable(let capability):
            return "Runtime capability unavailable: \(capability.rawValue)."
        case .mutationUnavailableByPolicy(let message):
            return "Runtime mutation unavailable by policy: \(message)"
        case .normalizedFailure(let failure):
            return "Runtime provider failure (\(failure.category.rawValue)): \(failure.diagnostic)"
        }
    }

    private func milliseconds(since start: UInt64) -> Int {
        let end = environment.benchmarkMonotonicNanoseconds()
        guard end >= start else { return 0 }
        return Int(clamping: (end - start) / 1_000_000)
    }

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private enum BenchmarkSessionError: Error, CustomStringConvertible {
    case capabilityUnavailable(String)
    case capabilityChanged(String)
    case invalidIdentity(String)
    case resourceCollision(String)
    case invalidPlan(String)
    case bootTimedOut(String)
    case statsIdentityMismatch(String)
    case ownershipMismatch(String)
    case cleanupTimedOut(String)
    case cleanupVerificationFailed(String)
    case postWakeObservationMissing(String)

    var description: String {
        switch self {
        case .capabilityUnavailable(let identifier):
            return "Runtime observation did not bind an immutable capability digest for \(identifier)."
        case .capabilityChanged(let identifier):
            return "Runtime capabilities changed while benchmarking \(identifier); mutation stopped before reuse."
        case .invalidIdentity(let identifier):
            return "Benchmark generated an unsupported resource identifier: \(identifier)."
        case .resourceCollision(let identifier):
            return "Benchmark resource already exists and will not be reused: \(identifier)."
        case .invalidPlan(let identifier):
            return "RuntimeAdapter did not return one exact create action for \(identifier)."
        case .bootTimedOut(let identifier):
            return "Benchmark resource did not reach running state within the bounded poll window: \(identifier)."
        case .statsIdentityMismatch(let identifier):
            return "Runtime stats were not bound to the exact benchmark identifier: \(identifier)."
        case .ownershipMismatch(let identifier):
            return "Cleanup refused an observation whose ownership identity did not match: \(identifier)."
        case .cleanupTimedOut(let identifier):
            return "Benchmark process did not reach an exact deletable lifecycle state before cleanup timeout: \(identifier)."
        case .cleanupVerificationFailed(let identifier):
            return "Benchmark identifier remained visible after exact cleanup: \(identifier)."
        case .postWakeObservationMissing(let identifier):
            return "The exact benchmark resource was not observable after the attended sleep/wake window: \(identifier)."
        }
    }
}
