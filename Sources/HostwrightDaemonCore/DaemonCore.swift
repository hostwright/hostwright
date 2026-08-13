import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightObservability
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

public enum DaemonMode: String, Equatable, Sendable {
    case foregroundDev = "foreground-dev"
    case managedService = "managed-service"
}

public enum DaemonWakeReason: String, Equatable, Sendable {
    case scheduled
    case configurationChanged
    case systemWake
    case shutdownRequested
}

public protocol DaemonControlServing: Sendable {
    func start() throws
    func stop()
}

public struct DaemonConfiguration: Equatable, Sendable {
    public let mode: DaemonMode
    public let configPath: String
    public let stateStoreConfiguration: StateStoreConfiguration
    public var stateDatabasePath: String { stateStoreConfiguration.databasePath }
    public let lockFilePath: String
    public let cadenceSeconds: Int
    public let jitterSeconds: Int
    public let maxBackoffSeconds: Int
    public let maximumParallelism: Int
    public let maxIterations: Int?

    public init(
        mode: DaemonMode = .foregroundDev,
        configPath: String,
        stateDatabasePath: String,
        lockFilePath: String? = nil,
        cadenceSeconds: Int = 5,
        jitterSeconds: Int = 0,
        maxBackoffSeconds: Int = 300,
        maximumParallelism: Int = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)),
        maxIterations: Int? = nil
    ) {
        self.mode = mode
        self.configPath = configPath
        self.stateStoreConfiguration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
        self.lockFilePath = lockFilePath ?? "\(stateDatabasePath).hostwrightd.lock"
        self.cadenceSeconds = cadenceSeconds
        self.jitterSeconds = jitterSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.maximumParallelism = maximumParallelism
        self.maxIterations = maxIterations
    }

    public init(
        mode: DaemonMode = .foregroundDev,
        configPath: String,
        stateStoreConfiguration: StateStoreConfiguration,
        lockFilePath: String,
        cadenceSeconds: Int = 5,
        jitterSeconds: Int = 0,
        maxBackoffSeconds: Int = 300,
        maximumParallelism: Int = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)),
        maxIterations: Int? = nil
    ) {
        self.mode = mode
        self.configPath = configPath
        self.stateStoreConfiguration = stateStoreConfiguration
        self.lockFilePath = lockFilePath
        self.cadenceSeconds = cadenceSeconds
        self.jitterSeconds = jitterSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.maximumParallelism = maximumParallelism
        self.maxIterations = maxIterations
    }

    public func validate() throws {
        guard !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DaemonError.invalidConfiguration("--config <path> is required.")
        }
        if mode == .managedService {
            do {
                guard try HostwrightLocalPathResolver.normalizedAbsolutePath(
                    configPath,
                    role: "managed daemon configuration"
                ) == configPath else {
                    throw DaemonError.invalidConfiguration(
                        "managed service configuration must be an absolute normalized path."
                    )
                }
            } catch let error as DaemonError {
                throw error
            } catch {
                throw DaemonError.invalidConfiguration(String(describing: error))
            }
            guard maxIterations == nil else {
                throw DaemonError.invalidConfiguration(
                    "--max-iterations is available only in foreground development mode."
                )
            }
        }
        do {
            try stateStoreConfiguration.validate()
            _ = try HostwrightLocalPathResolver.normalizedAbsolutePath(
                lockFilePath,
                role: "daemon lock"
            )
        } catch {
            throw DaemonError.invalidConfiguration(String(describing: error))
        }
        guard cadenceSeconds > 0 else {
            throw DaemonError.invalidConfiguration("--interval must be a positive integer.")
        }
        guard jitterSeconds >= 0 else {
            throw DaemonError.invalidConfiguration("--jitter must be zero or a positive integer.")
        }
        guard maxBackoffSeconds >= cadenceSeconds else {
            throw DaemonError.invalidConfiguration("--max-backoff must be greater than or equal to --interval.")
        }
        guard (1...32).contains(maximumParallelism) else {
            throw DaemonError.invalidConfiguration("--parallelism must be between 1 and 32.")
        }
        if cadenceSeconds + jitterSeconds > 5 {
            throw DaemonError.invalidConfiguration(
                "--interval plus --jitter must not exceed five seconds."
            )
        }
        if let maxIterations, maxIterations <= 0 {
            throw DaemonError.invalidConfiguration("--max-iterations must be a positive integer when provided.")
        }
    }
}

public enum DaemonError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidConfiguration(String)
    case lockUnavailable(path: String)
    case lockFailed(path: String, message: String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid daemon configuration: \(message)"
        case .lockUnavailable(let path):
            return "Another hostwrightd instance already holds lock file \(path)."
        case .lockFailed(let path, let message):
            return "Could not use daemon lock file \(path): \(message)"
        }
    }
}

public protocol DaemonClock: AnyObject {
    func timestamp() -> String
    func sleep(seconds: Int) async throws -> DaemonWakeReason
}

public protocol DaemonInstanceLock: AnyObject {
    func acquire() throws -> Bool
    func release()
}

public final class DaemonShutdownToken: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    public init() {}

    public var isShutdownRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    public func requestShutdown() {
        lock.lock()
        requested = true
        lock.unlock()
    }
}

public struct DaemonRunSummary: Equatable, Sendable {
    public let iterations: Int
    public let successfulIterations: Int
    public let failedIterations: Int
    public let stoppedByShutdown: Bool

    public init(iterations: Int, successfulIterations: Int, failedIterations: Int, stoppedByShutdown: Bool) {
        self.iterations = iterations
        self.successfulIterations = successfulIterations
        self.failedIterations = failedIterations
        self.stoppedByShutdown = stoppedByShutdown
    }
}

public struct DaemonLoopRunner {
    public var readConfig: (String) throws -> String
    public var readConfiguration: (
        String,
        DaemonConfigurationTargetKind,
        DaemonConfigurationTarget?
    ) throws -> DaemonConfigurationSnapshot
    public var idGenerator: (String) -> String
    public var jitterProvider: (Int, Int) -> Int

    private let configuration: DaemonConfiguration
    private let runtimeAdapter: any RuntimeAdapter
    private let reconciliationDriver: any DaemonReconciliationDriving
    private let healthChecker: any RuntimeHealthChecking
    private let clock: any DaemonClock
    private let instanceLock: any DaemonInstanceLock
    private let shutdownToken: DaemonShutdownToken
    private let configurationMonitor: DaemonConfigurationChangeMonitor?
    private let controlService: (any DaemonControlServing)?

    public init(
        configuration: DaemonConfiguration,
        runtimeAdapter: any RuntimeAdapter,
        reconciliationDriver: any DaemonReconciliationDriving,
        healthChecker: any RuntimeHealthChecking = BoundedRuntimeHealthChecker(),
        clock: any DaemonClock,
        instanceLock: any DaemonInstanceLock,
        shutdownToken: DaemonShutdownToken = DaemonShutdownToken(),
        configurationMonitor: DaemonConfigurationChangeMonitor? = nil,
        controlService: (any DaemonControlServing)? = nil,
        readConfig: @escaping (String) throws -> String,
        readConfiguration: ((
            String,
            DaemonConfigurationTargetKind,
            DaemonConfigurationTarget?
        ) throws -> DaemonConfigurationSnapshot)? = nil,
        idGenerator: @escaping (String) -> String = { "\(String($0))-\(UUID().uuidString)" },
        jitterProvider: @escaping (Int, Int) -> Int = DaemonLoopRunner.deterministicJitter
    ) {
        self.configuration = configuration
        self.runtimeAdapter = runtimeAdapter
        self.reconciliationDriver = reconciliationDriver
        self.healthChecker = healthChecker
        self.clock = clock
        self.instanceLock = instanceLock
        self.shutdownToken = shutdownToken
        self.configurationMonitor = configurationMonitor
        self.controlService = controlService
        self.readConfig = readConfig
        self.readConfiguration = readConfiguration ?? { path, kind, expected in
            let text = try readConfig(path)
            let data = Data(text.utf8)
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            let target = try DaemonConfigurationTarget(
                kind: kind,
                path: URL(fileURLWithPath: path).standardizedFileURL.path,
                contentSHA256: digest,
                byteCount: data.count,
                device: 1,
                inode: 1
            )
            if let expected, expected != target {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "A watched configuration target changed after validation; a fresh generation is required."
                )
            }
            return DaemonConfigurationSnapshot(target: target, text: text)
        }
        self.idGenerator = idGenerator
        self.jitterProvider = jitterProvider
    }

    public func run() async throws -> DaemonRunSummary {
        try configuration.validate()
        try configuration.stateStoreConfiguration.prepareRuntimeSupport()
        guard try instanceLock.acquire() else {
            throw DaemonError.lockUnavailable(path: configuration.lockFilePath)
        }
        defer { instanceLock.release() }
        defer { configurationMonitor?.stop() }

        let store = SQLiteStateStore(configuration: configuration.stateStoreConfiguration)
        try StateUpgradeService(store: store)
            .withBoundedStateAccessWait(lockWaitMilliseconds: 30_000) {
                _ = try StateUpgradeService(store: store).migrateToLatestWithVerifiedBackup()
            }
        return try await runStatefulLoop(store: store)
    }

    private func runStatefulLoop(store: SQLiteStateStore) async throws -> DaemonRunSummary {
        try controlService?.start()
        defer { controlService?.stop() }
        try recordLifecycleEvent(
            store: store,
            type: "daemon.started",
            severity: .info,
            message: "hostwrightd \(configuration.mode.rawValue) loop started."
        )

        var iterations = 0
        var successfulIterations = 0
        var failedIterations = 0
        var consecutiveFailures = 0
        var deferredStateContentionFailures = 0

        while !shutdownToken.isShutdownRequested {
            if let maxIterations = configuration.maxIterations, iterations >= maxIterations {
                break
            }

            iterations += 1
            let result: IterationResult
            do {
                result = try await runIteration(iteration: iterations, store: store)
            } catch let error as StateStoreError where Self.isTransientStateContention(error) {
                if deferredStateContentionFailures < 1_024 {
                    deferredStateContentionFailures += 1
                }
                result = .failure
            }
            switch result {
            case .success:
                successfulIterations += 1
                consecutiveFailures = 0
                if deferredStateContentionFailures > 0 {
                    let count = deferredStateContentionFailures
                    if try recordLifecycleEventIfStateAvailable(
                        store: store,
                        type: "daemon.backoff",
                        severity: .warning,
                        message: "hostwrightd resumed after \(count) transient state-access contention failure(s)."
                    ) {
                        deferredStateContentionFailures = 0
                    }
                }
            case .failure:
                failedIterations += 1
                consecutiveFailures += 1
            }

            if shutdownToken.isShutdownRequested {
                break
            }
            if let maxIterations = configuration.maxIterations, iterations >= maxIterations {
                break
            }

            let delay = delaySeconds(iteration: iterations, consecutiveFailures: consecutiveFailures)
            if consecutiveFailures > 0 {
                let recorded = try recordLifecycleEventIfStateAvailable(
                    store: store,
                    type: "daemon.backoff",
                    severity: .warning,
                    message: "hostwrightd backing off for \(delay) second(s) after \(consecutiveFailures) consecutive failure(s)."
                )
                if !recorded && deferredStateContentionFailures == 0 {
                    deferredStateContentionFailures = 1
                }
            }

            let wakeReason = try await clock.sleep(seconds: delay)
            switch wakeReason {
            case .scheduled:
                break
            case .configurationChanged:
                break
            case .systemWake:
                try recordLifecycleEvent(
                    store: store,
                    type: "daemon.sleep_wake_resumed",
                    severity: .info,
                    message: "hostwrightd resumed loop scheduling after system sleep/wake."
                )
            case .shutdownRequested:
                shutdownToken.requestShutdown()
            }
        }

        let stoppedByShutdown = shutdownToken.isShutdownRequested
        try recordLifecycleEvent(
            store: store,
            type: "daemon.stopped",
            severity: .info,
            message: stoppedByShutdown
                ? "hostwrightd \(configuration.mode.rawValue) loop stopped after shutdown request."
                : "hostwrightd \(configuration.mode.rawValue) loop stopped."
        )

        return DaemonRunSummary(
            iterations: iterations,
            successfulIterations: successfulIterations,
            failedIterations: failedIterations,
            stoppedByShutdown: stoppedByShutdown
        )
    }

    private enum IterationResult: Equatable {
        case success
        case failure
    }

    private func runIteration(iteration: Int, store: SQLiteStateStore) async throws -> IterationResult {
        return try await StateUpgradeService(store: store)
            .withSerializedLifecycleMutation(lockWaitMilliseconds: 30_000) {
            let traceID = HostwrightResourceUUID.legacy(
                kind: "daemon-trace",
                identifier: idGenerator("trace-daemon-\(iteration)")
            )
            guard let session = try? HostwrightTraceSession(
                traceID: traceID,
                processCorrelationID: HostwrightLogContext.correlationID ?? traceID,
                selected: HostwrightTraceSession.deterministicSelection(traceID: traceID)
            ) else {
                return try await runIterationUntraced(iteration: iteration, store: store)
            }
            session.attach(StateTraceSink(store: store))
            return try await HostwrightTraceContext.withSession(session) {
            let root = session.start(
                .daemonReconciliation,
                attributes: [
                    try? HostwrightTraceAttribute(key: .component, value: "daemon"),
                    try? HostwrightTraceAttribute(key: .daemonIteration, value: String(iteration)),
                    try? HostwrightTraceAttribute(key: .mode, value: configuration.mode.rawValue)
                ].compactMap { $0 }
            )
            return try await HostwrightTraceContext.withSpan(root) {
                do {
                    let result = try await runIterationUntraced(iteration: iteration, store: store)
                    let status: HostwrightTraceSpanStatus = result == .success ? .succeeded : .failed
                    let sampling = status == .succeeded
                        ? "deterministic-1-of-16"
                        : "failure-override"
                    try StateUpgradeService(store: store)
                        .withSerializedLifecycleMutation(lockWaitMilliseconds: 30_000) {
                            _ = session.finish(
                                root,
                                status: status,
                                attributes: session.rootCompletionAttributes(sampling: sampling)
                            )
                            session.complete(status: status)
                        }
                    return result
                } catch {
                    let status: HostwrightTraceSpanStatus = error is CancellationError ? .cancelled : .failed
                    try? StateUpgradeService(store: store)
                        .withSerializedLifecycleMutation(lockWaitMilliseconds: 30_000) {
                            _ = session.finish(
                                root,
                                status: status,
                                attributes: session.rootCompletionAttributes(sampling: "failure-override")
                            )
                            session.complete(status: status)
                        }
                    throw error
                }
            }
            }
        }
    }

    private func runIterationUntraced(iteration: Int, store: SQLiteStateStore) async throws -> IterationResult {
        let startedAt = clock.timestamp()
        var currentProjectID: String?
        var currentPlanHash = "unavailable"
        var enteredLifecycleDriver = false
        var configurationValidated = false
        do {
            let manifestPath = URL(fileURLWithPath: configuration.configPath).standardizedFileURL.path
            let manifestSnapshot = try readConfiguration(manifestPath, .manifest, nil)
            let manifestText = manifestSnapshot.text
            let manifest = try ManifestValidator.validated(manifestText)
            let configurationTargets = try DaemonConfigurationTargetResolver.paths(
                manifestPath: manifestPath,
                manifest: manifest
            ).map { kind, path in
                if kind == .manifest && path == manifestSnapshot.target.path {
                    return manifestSnapshot.target
                }
                return try readConfiguration(path, kind, nil).target
            }.sorted {
                ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path)
            }
            let configurationSetSHA256 = DaemonConfigurationSetDigest.sha256(configurationTargets)
            try configurationMonitor?.replace(paths: configurationTargets.map(\.path))
            configurationValidated = true
            let iterationResult: IterationResult = try await StateUpgradeService(store: store)
                .withSerializedLifecycleMutation(lockWaitMilliseconds: 250) {
            let mapping = ManifestRuntimeMapper.map(manifest)
            let projectID = "project-\(mapping.desiredState.projectName)"
            currentProjectID = projectID
            let observationDesiredState = DesiredRuntimeState(
                projectName: mapping.desiredState.projectName,
                networks: mapping.desiredState.networks,
                services: mapping.desiredState.services,
                ownedResourceHints: try store.ownership.runtimeHints(
                    projectID: projectID,
                    projectName: mapping.desiredState.projectName
                )
            )
            let observed = try await HostwrightTraceContext.withSpan(
                .providerObserve,
                attributes: [try? HostwrightTraceAttribute(key: .phase, value: "observe")]
                    .compactMap { $0 }
            ) {
                try await runtimeAdapter.observe(desiredState: observationDesiredState)
            }
            let adapterName = observed.adapterMetadata?.adapterName ?? "runtime-adapter"

            let healthResults = try await HostwrightTraceContext.withSpan(.healthEvaluate) {
                try await runHealthChecks(
                    desiredState: mapping.desiredState,
                    observedState: observed,
                    store: store,
                    projectID: projectID,
                    timestamp: startedAt
                )
            }
            let observedWithHealth = observedState(observed, applying: healthResults)
            var restartPolicyRecords = try restartPolicyStates(
                manifest: manifest,
                desiredState: mapping.desiredState,
                observedState: observedWithHealth,
                store: store,
                projectID: projectID,
                timestamp: startedAt
            )
            let restartPolicyStateMap = Dictionary(
                restartPolicyRecords.map { state in
                    (
                        RuntimeServiceIdentity(
                            projectName: mapping.desiredState.projectName,
                            serviceName: state.serviceName
                        ),
                        state
                    )
                },
                uniquingKeysWith: { first, _ in first }
            )
            let plan = HostwrightTraceContext.withSpan(.planCompile) {
                ReconciliationPlanner().plan(
                    manifest: manifest,
                    observedState: observedWithHealth,
                    restartPolicyStates: restartPolicyStateMap,
                    currentTimestamp: startedAt
                )
            }
            currentPlanHash = plan.planHash
            guard !plan.includesBlockers else {
                throw HostwrightDiagnostic(
                    code: .unsafeExposure,
                    message: "The unattended reconciliation plan contains blocking issues. No runtime mutation was admitted."
                )
            }
            let selectedServiceNames = selectedLifecycleServices(
                manifest: manifest,
                plan: plan
            )
            let operationIdempotencyKeySHA256 = try restartOperationIdempotencyKey(
                plan: plan,
                restartPolicyRecords: restartPolicyRecords,
                projectID: projectID
            )
            let maintenance = try maintenanceAdmission(
                manifest: manifest,
                plan: plan,
                store: store,
                projectID: projectID,
                manifestPath: manifestPath,
                manifestSHA256: manifestSnapshot.target.contentSHA256,
                timestamp: startedAt
            )
            let reconciliation: DaemonReconciliationResult
            if let deferred = maintenance.deferredResult {
                reconciliation = deferred
            } else {
                enteredLifecycleDriver = true
                do {
                    let request = try DaemonReconciliationRequest(
                        manifestPath: manifestPath,
                        manifestSHA256: manifestSnapshot.target.contentSHA256,
                        configurationSetSHA256: configurationSetSHA256,
                        configurationTargets: configurationTargets,
                        stateDatabasePath: configuration.stateDatabasePath,
                        projectID: projectID,
                        maximumParallelism: configuration.maximumParallelism,
                        selectedServiceNames: selectedServiceNames,
                        operationIdempotencyKeySHA256:
                            operationIdempotencyKeySHA256,
                        maintenanceAdmission: maintenance.binding
                    )
                    reconciliation = try await StateUpgradeService(store: store)
                        .withSerializedLifecycleMutation(lockWaitMilliseconds: 30_000) {
                            try await reconciliationDriver.reconcile(request: request)
                        }
                } catch {
                    try recordMaintenanceCompletion(
                        maintenance,
                        reconciliation: nil,
                        store: store,
                        projectID: projectID,
                        timestamp: clock.timestamp()
                    )
                    throw error
                }
                try recordMaintenanceCompletion(
                    maintenance,
                    reconciliation: reconciliation,
                    store: store,
                    projectID: projectID,
                    timestamp: clock.timestamp()
                )
            }
            var restartAttemptHistory: [RestartAttemptHistoryRecord] = []
            if reconciliation.runtimeMutationAttempted {
                let eligibleRestartServices = Set(plan.actions.compactMap { action -> String? in
                    switch action.executionAvailability {
                    case .availableForStartManagedService, .availableForRestartManagedService:
                        return action.identity.serviceName
                    case .unavailable, .availableForCreateMissingService:
                        return nil
                    }
                })
                let attemptedRestartServices = eligibleRestartServices.intersection(
                    Set(reconciliation.attemptedServiceNames ?? [])
                )
                if !attemptedRestartServices.isEmpty {
                    let projectWindow = manifest.restartBudget?.window
                        ?? RestartPolicyStateDefaults.projectWindowSeconds
                    var projectAttempt = try projectRestartAttemptCount(
                        store: store,
                        projectID: projectID,
                        timestamp: startedAt,
                        windowSeconds: projectWindow
                    )
                    restartPolicyRecords = restartPolicyRecords.map { state in
                        guard attemptedRestartServices.contains(state.serviceName) else {
                            return state
                        }
                        projectAttempt += 1
                        let result = RestartPolicyEvaluator.admittedAttempt(
                            state: state,
                            projectAttemptNumber: projectAttempt,
                            operationID: reconciliation.operationID,
                            failed: !reconciliation.status.isSuccessfulIteration,
                            reasonOverride: reconciliation.status == .interrupted ||
                                reconciliation.status == .safeHold
                                ? .unknown
                                : nil,
                            timestamp: startedAt,
                            historyID: HostwrightResourceUUID.legacy(
                                kind: "restart-attempt",
                                identifier: idGenerator("restart-attempt")
                            )
                        )
                        restartAttemptHistory.append(result.history)
                        return result.state
                    }
                }
            }
            try persistHealthResults(
                healthResults,
                store: store,
                projectID: projectID,
                checkedAt: startedAt
            )
            try persistRestartPolicyStates(
                restartPolicyRecords,
                attempts: restartAttemptHistory,
                store: store,
                projectID: projectID,
                timestamp: startedAt
            )
            try store.observedStates.saveSnapshot(
                snapshotID: idGenerator("daemon-snapshot"),
                projectID: projectID,
                observedState: observedWithHealth,
                runtimeAdapter: adapterName,
                parserVersion: "daemon-observation-v2",
                rawOutputHash: nil,
                redactedSummary: PlanRenderer.render(plan, mode: .compact),
                observedAt: startedAt
            )
            let iterationSucceeded = reconciliation.status.isSuccessfulIteration
            if iterationSucceeded {
                try recordConfigurationAccepted(
                    store: store,
                    projectID: projectID,
                    configurationSetSHA256: configurationSetSHA256,
                    manifestSHA256: manifestSnapshot.target.contentSHA256,
                    targetCount: configurationTargets.count,
                    timestamp: startedAt
                )
            }
            let completedAt = clock.timestamp()
            var reconciliationPayload: [String: Any] = [
                "actions": plan.actions.count,
                "drift": plan.drift.count,
                "healthChecks": healthResults.count,
                "checkpoint": reconciliation.checkpoint,
                "completedNodes": reconciliation.completedNodeCount,
                "lifecyclePlanSHA256": reconciliation.planSHA256,
                "mutationAttempted": reconciliation.runtimeMutationAttempted,
                "nodes": reconciliation.nodeCount,
                "planHash": plan.planHash,
                "reasonCode": reconciliation.reasonCode.rawValue,
                "restartPolicyBlocked": plan.issues.filter { $0.kind == .restartPolicyBlocked }.count
            ]
            if let duration = durationMilliseconds(from: startedAt, to: completedAt) {
                reconciliationPayload["durationMilliseconds"] = duration
            }
            try store.operations.record(
                OperationRecord(
                    id: idGenerator("operation-daemon"),
                    createdAt: startedAt,
                    updatedAt: completedAt,
                    plannedActionType: "daemon.reconcile",
                    projectID: projectID,
                    serviceName: nil,
                    status: iterationSucceeded ? .succeeded : .failed,
                    idempotencyKey: "daemon:\(iteration)",
                    planHash: plan.planHash,
                    payloadJSONRedacted: payload(reconciliationPayload)
                )
            )
            try store.events.append([
                EventRecord(
                    id: idGenerator("event-daemon"),
                    timestamp: startedAt,
                    severity: iterationSucceeded ? .info : .warning,
                    type: reconciliation.reasonCode.rawValue,
                    source: "hostwrightd",
                    projectID: projectID,
                    serviceName: nil,
                    runtimeAdapter: adapterName,
                    message: "Daemon reconciliation \(reconciliation.status.rawValue): observed \(observedWithHealth.services.count) service(s), recorded \(healthResults.count) health check result(s), planned \(reconciliation.nodeCount) lifecycle node(s), and completed \(reconciliation.completedNodeCount).",
                    payloadJSONRedacted: payload(reconciliationPayload)
                )
            ])
            return iterationSucceeded ? .success : .failure
            }
            return iterationResult
        } catch {
            let diagnostic = daemonDiagnostic(for: error)
            let message = RuntimeRedactionPolicy.default.redact(diagnostic.message)
            if !configurationValidated {
                try recordConfigurationRejected(
                    store: store,
                    diagnostic: diagnostic,
                    timestamp: startedAt
                )
            }
            let evidenceProjectID: String?
            if let currentProjectID,
               (try? store.desiredStates.loadProject(id: currentProjectID)) != nil {
                evidenceProjectID = currentProjectID
            } else {
                evidenceProjectID = nil
            }
            let completedAt = clock.timestamp()
            var failurePayload: [String: Any] = [
                "error": message,
                "errorCode": diagnostic.code.rawValue,
                "mutationOutcome": enteredLifecycleDriver
                    ? "inspect-lifecycle-ledger"
                    : "not-admitted"
            ]
            if let duration = durationMilliseconds(from: startedAt, to: completedAt) {
                failurePayload["durationMilliseconds"] = duration
            }
            try store.operations.record(
                OperationRecord(
                    id: idGenerator("operation-daemon"),
                    createdAt: startedAt,
                    updatedAt: completedAt,
                    plannedActionType: "daemon.reconcile",
                    projectID: evidenceProjectID,
                    serviceName: nil,
                    status: .failed,
                    idempotencyKey: "daemon:\(iteration)",
                    planHash: currentPlanHash,
                    payloadJSONRedacted: payload(failurePayload)
                )
            )
            try store.events.append([
                EventRecord(
                    id: idGenerator("event-daemon"),
                    timestamp: startedAt,
                    severity: .error,
                    type: "daemon.reconcile.failed",
                    source: "hostwrightd",
                    projectID: evidenceProjectID,
                    serviceName: nil,
                    runtimeAdapter: nil,
                    message: enteredLifecycleDriver
                        ? "Daemon reconciliation failed; inspect the fenced lifecycle ledger before retry: \(diagnostic.code.rawValue): \(message)"
                        : "Daemon reconciliation failed before lifecycle admission: \(diagnostic.code.rawValue): \(message)",
                    payloadJSONRedacted: payload(failurePayload)
                )
            ])
            return .failure
        }
    }

    private func recordConfigurationAccepted(
        store: SQLiteStateStore,
        projectID: String,
        configurationSetSHA256: String,
        manifestSHA256: String,
        targetCount: Int,
        timestamp: String
    ) throws {
        let pathSHA256 = sha256(
            URL(fileURLWithPath: configuration.configPath).standardizedFileURL.path
        )
        let pathFragment = #""configurationPathSHA256":"\#(pathSHA256)""#
        let priorCount = try store.events.count(
            type: "daemon.configuration.accepted",
            source: "hostwrightd",
            payloadContains: pathFragment
        )
        if try store.events.contains(
            type: "daemon.configuration.accepted",
            source: "hostwrightd",
            payloadContains: #""configurationSetSHA256":"\#(configurationSetSHA256)""#
        ) {
            return
        }
        try store.events.append([
            EventRecord(
                id: idGenerator("event-daemon-configuration"),
                timestamp: timestamp,
                severity: .info,
                type: "daemon.configuration.accepted",
                source: "hostwrightd",
                projectID: projectID,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "Validated daemon configuration generation \(priorCount + 1) became authoritative.",
                payloadJSONRedacted: payload([
                    "configurationGeneration": priorCount + 1,
                    "configurationPathSHA256": pathSHA256,
                    "configurationSetSHA256": configurationSetSHA256,
                    "manifestSHA256": manifestSHA256,
                    "targetCount": targetCount
                ])
            )
        ])
    }

    private func recordConfigurationRejected(
        store: SQLiteStateStore,
        diagnostic: HostwrightDiagnostic,
        timestamp: String
    ) throws {
        let pathSHA256 = sha256(
            URL(fileURLWithPath: configuration.configPath).standardizedFileURL.path
        )
        let fingerprint = sha256("\(pathSHA256)\u{1f}\(diagnostic.code.rawValue)\u{1f}\(diagnostic.message)")
        if try store.events.contains(
            type: "daemon.configuration.rejected",
            source: "hostwrightd",
            payloadContains: #""fingerprint":"\#(fingerprint)""#
        ) {
            return
        }
        try store.events.append([
            EventRecord(
                id: idGenerator("event-daemon-configuration"),
                timestamp: timestamp,
                severity: .warning,
                type: "daemon.configuration.rejected",
                source: "hostwrightd",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "Rejected daemon configuration; the prior authoritative desired generation was retained.",
                payloadJSONRedacted: payload([
                    "configurationPathSHA256": pathSHA256,
                    "errorCode": diagnostic.code.rawValue,
                    "fingerprint": fingerprint,
                    "priorGenerationRetained": true
                ])
            )
        ])
    }

    private func runHealthChecks(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState,
        store: SQLiteStateStore,
        projectID: String,
        timestamp: String
    ) async throws -> [RuntimeHealthCheckResult] {
        let observedByIdentity = Dictionary(
            observedState.services.map { (normalizedIdentity($0.identity), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var results: [RuntimeHealthCheckResult] = []

        for desired in desiredState.services.sorted(by: { $0.identity.displayName < $1.identity.displayName }) {
            guard let healthCheck = desired.healthCheck else {
                continue
            }

            if let latest = try store.healthResults.latest(projectID: projectID, serviceName: desired.identity.serviceName),
               !isHealthCheckDue(lastCheckedAt: latest.checkedAt, intervalSeconds: healthCheck.intervalSeconds, now: timestamp) {
                continue
            }

            guard let observed = observedByIdentity[normalizedIdentity(desired.identity)],
                  observed.lifecycleState == .running else {
                results.append(
                    RuntimeHealthCheckResult(
                        identity: desired.identity,
                        status: .skipped,
                        exitStatus: nil,
                        timedOut: false,
                        command: RuntimeRedactionPolicy.default.redact(arguments: healthCheck.command),
                        standardOutput: "",
                        standardError: "Health check skipped because the observed service is not running."
                    )
                )
                continue
            }

            results.append(await healthChecker.check(identity: desired.identity, spec: healthCheck))
        }

        return results
    }

    private func persistHealthResults(
        _ results: [RuntimeHealthCheckResult],
        store: SQLiteStateStore,
        projectID: String,
        checkedAt: String
    ) throws {
        guard !results.isEmpty else {
            return
        }

        let records = results.map { result in
            HealthCheckResultRecord(
                id: idGenerator("health-result"),
                projectID: projectID,
                serviceName: result.identity.serviceName,
                checkedAt: checkedAt,
                status: result.status,
                exitStatus: result.exitStatus,
                timedOut: result.timedOut,
                commandJSONRedacted: jsonArray(result.command),
                stdoutRedacted: result.standardOutput,
                stderrRedacted: result.standardError,
                metadataJSONRedacted: payload([
                    "timedOut": result.timedOut,
                    "status": result.status.rawValue
                ])
            )
        }
        try store.healthResults.append(records)

        try store.events.append(results.map { result in
            EventRecord(
                id: idGenerator("event-health"),
                timestamp: checkedAt,
                severity: healthEventSeverity(result.status),
                type: "health.check.\(result.status.rawValue)",
                source: "hostwrightd",
                projectID: projectID,
                serviceName: result.identity.serviceName,
                runtimeAdapter: nil,
                message: "Health check for \(result.identity.displayName) recorded \(result.status.rawValue).",
                payloadJSONRedacted: payload([
                    "command": result.command,
                    "exitStatus": result.exitStatus.map { Int($0) } ?? NSNull(),
                    "stderr": result.standardError,
                    "stdout": result.standardOutput,
                    "timedOut": result.timedOut
                ])
            )
        })
    }

    private func observedState(
        _ observedState: ObservedRuntimeState,
        applying healthResults: [RuntimeHealthCheckResult]
    ) -> ObservedRuntimeState {
        let resultsByIdentity = Dictionary(
            healthResults.map { (normalizedIdentity($0.identity), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let services = observedState.services.map { service in
            guard let result = resultsByIdentity[normalizedIdentity(service.identity)] else {
                return service
            }

            let healthState: RuntimeHealthState
            switch result.status {
            case .healthy:
                healthState = .healthy
            case .unhealthy:
                healthState = .unhealthy
            case .unknown:
                healthState = .unknown
            case .skipped, .notConfigured:
                healthState = service.healthState
            }

            return ObservedRuntimeService(
                identity: service.identity,
                resourceIdentifier: service.resourceIdentifier,
                image: service.image,
                lifecycleState: service.lifecycleState,
                healthState: healthState,
                ports: service.ports,
                publishedSockets: service.publishedSockets,
                networks: service.networks,
                mounts: service.mounts,
                observedAt: service.observedAt
            )
        }

        return ObservedRuntimeState(
            projectName: observedState.projectName,
            services: services,
            adapterMetadata: observedState.adapterMetadata,
            capabilitySHA256: observedState.capabilitySHA256
        )
    }

    private func restartPolicyStates(
        manifest: HostwrightManifest,
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState,
        store: SQLiteStateStore,
        projectID: String,
        timestamp: String
    ) throws -> [RestartPolicyStateRecord] {
        let observedByIdentity = Dictionary(
            observedState.services.map { (normalizedIdentity($0.identity), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingStates = Dictionary(
            try store.restartPolicies.loadProject(projectID: projectID).map { ($0.serviceName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let manifestServices = Dictionary(
            manifest.services.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let projectWindow = manifest.restartBudget?.window
            ?? RestartPolicyStateDefaults.projectWindowSeconds
        let projectMaximum = manifest.restartBudget?.maxAttempts
            ?? RestartPolicyStateDefaults.projectMaxAttempts
        let projectUsed = try projectRestartAttemptCount(
            store: store,
            projectID: projectID,
            timestamp: timestamp,
            windowSeconds: projectWindow
        )
        var projectRemaining = max(0, projectMaximum - projectUsed)
        var records: [RestartPolicyStateRecord] = []

        let orderedDesired = desiredState.services.sorted { left, right in
            let leftPriority = manifestServices[left.identity.serviceName]?.restart?.priority ?? 0
            let rightPriority = manifestServices[right.identity.serviceName]?.restart?.priority ?? 0
            return leftPriority == rightPriority
                ? left.identity.displayName < right.identity.displayName
                : leftPriority > rightPriority
        }
        for desired in orderedDesired {
            let observed = observedByIdentity[normalizedIdentity(desired.identity)]
            let previous = existingStates[desired.identity.serviceName]
            let policy = RestartBudgetPolicy(
                service: manifestServices[desired.identity.serviceName]?.restart,
                project: manifest.restartBudget
            )
            let restartCandidate = observed.map {
                $0.lifecycleState == .stopped || $0.lifecycleState == .exited ||
                    ($0.lifecycleState == .running && $0.healthState == .unhealthy)
            } ?? false
            let state = RestartPolicyEvaluator.preparedState(
                id: previous?.id ?? idGenerator("restart-policy"),
                projectID: projectID,
                serviceName: desired.identity.serviceName,
                restartPolicy: desired.restartPolicy,
                policy: policy,
                observedLifecycle: observed?.lifecycleState,
                observedHealth: observed?.healthState,
                dependencyUnavailable: hasUnavailableDependency(
                    desired,
                    observedState: observedState
                ),
                previous: previous,
                projectCapacityAvailable: !restartCandidate || projectRemaining > 0,
                timestamp: timestamp
            )
            records.append(state)
            if restartCandidate && state.status == .active && desired.restartPolicy.allowsManagedStart {
                projectRemaining = max(0, projectRemaining - 1)
            }
        }
        return records.sorted { $0.serviceName < $1.serviceName }
    }

    private func persistRestartPolicyStates(
        _ records: [RestartPolicyStateRecord],
        attempts: [RestartAttemptHistoryRecord] = [],
        store: SQLiteStateStore,
        projectID: String,
        timestamp: String
    ) throws {
        let attemptsByService = Dictionary(
            attempts.map { ($0.serviceName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var events: [EventRecord] = []
        for record in records {
            let previous = try store.restartPolicies.load(
                projectID: projectID,
                serviceName: record.serviceName
            )
            if let attempt = attemptsByService[record.serviceName] {
                try store.restartPolicies.recordAttempt(state: record, history: attempt)
            } else if let previous, let transition = restartTransition(
                from: previous,
                to: record,
                projectID: projectID,
                timestamp: timestamp
            ) {
                try store.restartPolicies.recordTransition(state: record, history: transition)
            } else if let previous, restartPolicyStateIsEquivalent(previous, record) {
                continue
            } else {
                try store.restartPolicies.upsert(record)
            }
            events.append(
                EventRecord(
                    id: idGenerator("event-restart-policy"),
                    timestamp: timestamp,
                    severity: restartStateSeverity(record.status),
                    type: "restart.policy.state",
                    source: "hostwrightd",
                    projectID: projectID,
                    serviceName: record.serviceName,
                    runtimeAdapter: nil,
                    message: "Restart policy state for \(projectID)/\(record.serviceName) is \(record.status.rawValue) after lifecycle reconciliation.",
                    payloadJSONRedacted: record.metadataJSONRedacted
                )
            )
        }
        if !events.isEmpty { try store.events.append(events) }
    }

    private func projectRestartAttemptCount(
        store: SQLiteStateStore,
        projectID: String,
        timestamp: String,
        windowSeconds: Int
    ) throws -> Int {
        let formatter = ISO8601DateFormatter()
        guard let now = formatter.date(from: timestamp) else {
            throw HostwrightDiagnostic(
                code: .daemonInvalid,
                message: "Restart budget evaluation requires a canonical timestamp."
            )
        }
        let since = formatter.string(
            from: now.addingTimeInterval(-TimeInterval(windowSeconds))
        )
        return try store.restartAttempts.admittedCount(
            projectID: projectID,
            since: since
        )
    }

    private func hasUnavailableDependency(
        _ desired: DesiredRuntimeService,
        observedState: ObservedRuntimeState
    ) -> Bool {
        desired.dependencies.contains { dependency in
            let candidates = observedState.services.filter {
                $0.identity.projectName == desired.identity.projectName &&
                    $0.identity.serviceName == dependency.serviceName
            }
            switch dependency.condition {
            case .started:
                return !candidates.contains { $0.lifecycleState == .running }
            case .ready:
                return !candidates.contains {
                    $0.lifecycleState == .running && $0.healthState == .healthy
                }
            case .completed:
                return !candidates.contains { $0.lifecycleState == .exited }
            }
        }
    }

    private func restartTransition(
        from previous: RestartPolicyStateRecord,
        to current: RestartPolicyStateRecord,
        projectID: String,
        timestamp: String
    ) -> RestartAttemptHistoryRecord? {
        let decision: RestartAttemptDecision
        switch current.status {
        case .crashLoopBlocked where previous.status != .crashLoopBlocked,
             .operatorHold where previous.status != .operatorHold:
            guard current.holdToken != nil else { return nil }
            decision = .hold
        case .projectBudgetBlocked where previous.status != .projectBudgetBlocked:
            decision = .denied
        case .active where previous.attemptCount > 0 && current.attemptCount == 0:
            decision = .stableReset
        default:
            return nil
        }
        return RestartAttemptHistoryRecord(
            id: HostwrightResourceUUID.legacy(
                kind: "restart-transition",
                identifier: idGenerator("restart-transition")
            ),
            projectID: projectID,
            serviceName: current.serviceName,
            reasonClass: current.reasonClass,
            decision: decision,
            attemptNumber: previous.attemptCount,
            projectAttemptNumber: 0,
            admitted: false,
            holdToken: current.holdToken,
            releaseGeneration: current.releaseGeneration,
            occurredAt: timestamp,
            backoffUntil: current.backoffUntil,
            policySHA256: current.policySHA256,
            metadataJSONRedacted: current.metadataJSONRedacted
        )
    }

    private func restartPolicyStateIsEquivalent(
        _ left: RestartPolicyStateRecord,
        _ right: RestartPolicyStateRecord
    ) -> Bool {
        left.id == right.id &&
            left.projectID == right.projectID &&
            left.serviceName == right.serviceName &&
            left.policy == right.policy &&
            left.status == right.status &&
            left.attemptCount == right.attemptCount &&
            left.maxAttempts == right.maxAttempts &&
            left.backoffSeconds == right.backoffSeconds &&
            left.backoffUntil == right.backoffUntil &&
            left.lastFailureAt == right.lastFailureAt &&
            left.reasonClass == right.reasonClass &&
            left.windowStartedAt == right.windowStartedAt &&
            left.windowSeconds == right.windowSeconds &&
            left.initialBackoffSeconds == right.initialBackoffSeconds &&
            left.maximumBackoffSeconds == right.maximumBackoffSeconds &&
            left.jitterSeconds == right.jitterSeconds &&
            left.stableRunSeconds == right.stableRunSeconds &&
            left.stableSince == right.stableSince &&
            left.priority == right.priority &&
            left.projectMaxAttempts == right.projectMaxAttempts &&
            left.projectWindowSeconds == right.projectWindowSeconds &&
            left.holdToken == right.holdToken &&
            left.releaseGeneration == right.releaseGeneration &&
            left.policySHA256 == right.policySHA256 &&
            left.metadataJSONRedacted == right.metadataJSONRedacted
    }

    private func normalizedIdentity(_ identity: RuntimeServiceIdentity) -> RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: identity.projectName, serviceName: identity.serviceName)
    }

    private func selectedLifecycleServices(
        manifest: HostwrightManifest,
        plan: ReconciliationPlan
    ) -> [String]? {
        var excluded = Set(plan.actions.compactMap { action -> String? in
            switch action.kind {
            case .proposeStartStoppedService, .restartManagedService:
                return action.executionAvailability == .unavailable
                    ? action.identity.serviceName
                    : nil
            default:
                return nil
            }
        })
        guard !excluded.isEmpty else { return nil }
        var changed = true
        while changed {
            changed = false
            for service in manifest.services where !excluded.contains(service.name) &&
                !Set(service.dependsOn.keys).isDisjoint(with: excluded) {
                excluded.insert(service.name)
                changed = true
            }
        }
        return manifest.services.map(\.name).filter { !excluded.contains($0) }.sorted()
    }

    private struct PreparedMaintenanceAdmission {
        let binding: DaemonMaintenanceAdmission?
        let deferredResult: DaemonReconciliationResult?
        let pending: MaintenanceDeferralRecord?
    }

    private func maintenanceAdmission(
        manifest: HostwrightManifest,
        plan: ReconciliationPlan,
        store: SQLiteStateStore,
        projectID: String,
        manifestPath: String,
        manifestSHA256: String,
        timestamp: String
    ) throws -> PreparedMaintenanceAdmission {
        let actions = Self.maintenanceActionClasses(plan: plan)
        guard let policy = manifest.maintenance, !actions.isEmpty else {
            return PreparedMaintenanceAdmission(binding: nil, deferredResult: nil, pending: nil)
        }
        let planSHA256 = sha256(plan.planHash)
        let policySHA256 = MaintenanceWindowEvaluator.policySHA256(policy)
        if try store.operationGroups.loadAll().contains(where: {
            $0.projectID == projectID && $0.status == .active
        }) {
            return PreparedMaintenanceAdmission(
                binding: try DaemonMaintenanceAdmission(
                    reconciliationPlanSHA256: planSHA256,
                    policySHA256: policySHA256,
                    actionClasses: [HostwrightMaintenanceActionClass.recovery.rawValue],
                    reason: MaintenanceAdmissionReason.safetyRecovery.rawValue,
                    confirmationToken: nil,
                    windowID: nil,
                    windowStartsAt: nil,
                    windowEndsAt: nil
                ),
                deferredResult: nil,
                pending: nil
            )
        }
        guard let now = ISO8601DateFormatter().date(from: timestamp) else {
            throw HostwrightDiagnostic(code: .daemonInvalid, message: "Daemon maintenance admission received an invalid clock timestamp.")
        }
        var pending = try store.maintenanceDeferrals.latest(projectID: projectID)
        let matches = pending.map {
            $0.planSHA256 == planSHA256 &&
                $0.policySHA256 == policySHA256 &&
                $0.actionClasses == actions &&
                [.deferred, .cancelled, .overrideAuthorized].contains($0.state)
        } == true
        if !matches {
            if let current = pending,
               current.state == .deferred || current.state == .overrideAuthorized {
                _ = try store.maintenanceDeferrals.supersede(
                    projectID: projectID,
                    expectedConfirmationToken: current.confirmationToken,
                    updatedAt: timestamp
                )
            }
            pending = nil
        }
        var decision = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: actions,
            now: now,
            deferredAt: pending.flatMap { ISO8601DateFormatter().date(from: $0.firstDeferredAt) },
            cancelled: pending?.state == .cancelled,
            emergencyOverrideAuthorized: pending?.state == .overrideAuthorized
        )
        if !decision.admitted, pending == nil {
            let prior = try? store.desiredStates.loadProject(id: projectID)
            let generation = max(
                1,
                (prior?.providerGeneration ?? 0) +
                    ((prior?.manifestHash == manifestSHA256) ? 0 : 1)
            )
            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: manifestPath,
                manifestHash: manifestSHA256,
                desiredGeneration: generation,
                manifest: manifest,
                timestamp: timestamp,
                mutationProvider: prior?.mutationProvider
            )
            let deadline = ISO8601DateFormatter().string(
                from: now.addingTimeInterval(TimeInterval(policy.maximumDeferral))
            )
            pending = try store.maintenanceDeferrals.deferPlan(
                projectID: projectID,
                planSHA256: planSHA256,
                policySHA256: policySHA256,
                actionClasses: actions,
                firstDeferredAt: timestamp,
                deadlineAt: deadline,
                reasonRedacted: "Elective runtime mutation is outside an allowed maintenance window."
            )
            decision = MaintenanceWindowEvaluator.evaluate(
                policy: policy,
                actions: actions,
                now: now,
                deferredAt: now
            )
        }
        if !decision.admitted {
            let reasonCode: DaemonReconciliationReasonCode
            switch decision.reason {
            case .deadlineExpired:
                reasonCode = .maintenanceDeadlineExpired
            case .cancelled:
                reasonCode = .maintenanceCancelled
            default:
                reasonCode = .maintenanceDeferred
            }
            return PreparedMaintenanceAdmission(
                binding: nil,
                deferredResult: try DaemonReconciliationResult(
                    status: .deferred,
                    reasonCode: reasonCode,
                    planSHA256: planSHA256,
                    nodeCount: 0,
                    completedNodeCount: 0,
                    runtimeMutationAttempted: false,
                    attemptedServiceNames: [],
                    checkpoint: decision.reason.rawValue,
                    recoveryHintRedacted: pending.map { _ in
                        "Inspect hostwright maintenance status and use only its exact confirmation token."
                    } ?? ""
                ),
                pending: pending
            )
        }
        let active = decision.activeWindow
        return PreparedMaintenanceAdmission(
            binding: try DaemonMaintenanceAdmission(
                reconciliationPlanSHA256: planSHA256,
                policySHA256: policySHA256,
                actionClasses: actions.map(\.rawValue),
                reason: decision.reason.rawValue,
                confirmationToken: pending?.confirmationToken,
                windowID: active?.windowID,
                windowStartsAt: active?.startsAt,
                windowEndsAt: active?.endsAt
            ),
            deferredResult: nil,
            pending: pending
        )
    }

    static func maintenanceActionClasses(
        plan: ReconciliationPlan
    ) -> [HostwrightMaintenanceActionClass] {
        Array(Set(plan.actions.compactMap { action in
            switch (action.kind, action.executionAvailability) {
            case (.createMissingService, .availableForCreateMissingService): .create
            case (.proposeStartStoppedService, .availableForStartManagedService): .start
            case (.restartManagedService, .availableForRestartManagedService): .restart
            case (.replaceForImageDrift, _),
                 (.reconcilePortDrift, _),
                 (.reconcileMountDrift, _): .update
            default: nil
            }
        })).sorted { $0.rawValue < $1.rawValue }
    }

    private func recordMaintenanceCompletion(
        _ maintenance: PreparedMaintenanceAdmission,
        reconciliation: DaemonReconciliationResult?,
        store: SQLiteStateStore,
        projectID: String,
        timestamp: String
    ) throws {
        guard let pending = maintenance.pending,
              maintenance.binding != nil else { return }
        let succeeded = reconciliation?.status.isSuccessfulIteration == true
        _ = try store.maintenanceDeferrals.recordAdmission(
            projectID: projectID,
            expectedConfirmationToken: pending.confirmationToken,
            state: succeeded ? .admitted : .failed,
            windowID: maintenance.binding?.windowID,
            reasonRedacted: succeeded
                ? "The exact maintenance-bound reconciliation completed its admitted iteration."
                : "The exact maintenance-bound reconciliation failed after lifecycle admission; inspect its durable saga evidence.",
            updatedAt: timestamp
        )
    }

    private func restartOperationIdempotencyKey(
        plan: ReconciliationPlan,
        restartPolicyRecords: [RestartPolicyStateRecord],
        projectID: String
    ) throws -> String? {
        let services = Set(plan.actions.compactMap { action -> String? in
            switch action.executionAvailability {
            case .availableForStartManagedService, .availableForRestartManagedService:
                return action.identity.serviceName
            case .unavailable, .availableForCreateMissingService:
                return nil
            }
        })
        guard !services.isEmpty else { return nil }
        let states = Dictionary(
            restartPolicyRecords.map { ($0.serviceName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let components = try services.sorted().map { serviceName -> String in
            guard let state = states[serviceName], state.status == .active else {
                throw HostwrightDiagnostic(
                    code: .daemonInvalid,
                    message: "A restart mutation was selected without one exact admitted budget generation. No mutation was attempted."
                )
            }
            return [
                serviceName,
                String(state.attemptCount + 1),
                String(state.releaseGeneration),
                state.policySHA256
            ].joined(separator: ":")
        }
        let material = ([
            "daemon-restart-operation-v1",
            projectID,
            plan.planHash
        ] + components).joined(separator: "\n")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func healthEventSeverity(_ status: RuntimeHealthCheckStatus) -> StateEventSeverity {
        switch status {
        case .healthy, .notConfigured:
            return .info
        case .skipped, .unknown:
            return .warning
        case .unhealthy:
            return .error
        }
    }

    private func restartStateSeverity(_ status: RestartPolicyStateStatus) -> StateEventSeverity {
        switch status {
        case .active, .stablePending:
            return .info
        case .backingOff, .operatorHold, .manualDisabled, .projectBudgetBlocked:
            return .warning
        case .crashLoopBlocked:
            return .error
        }
    }

    private func isHealthCheckDue(lastCheckedAt: String, intervalSeconds: Int, now: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let last = formatter.date(from: lastCheckedAt),
              let current = formatter.date(from: now) else {
            return true
        }
        return current.timeIntervalSince(last) >= TimeInterval(intervalSeconds)
    }

    private func delaySeconds(iteration: Int, consecutiveFailures: Int) -> Int {
        let base: Int
        if consecutiveFailures == 0 {
            base = configuration.cadenceSeconds
        } else {
            let shift = min(consecutiveFailures - 1, 10)
            base = min(configuration.maxBackoffSeconds, configuration.cadenceSeconds * (1 << shift))
        }

        let jitter = configuration.jitterSeconds == 0 ? 0 : max(0, min(configuration.jitterSeconds, jitterProvider(iteration, configuration.jitterSeconds)))
        return min(configuration.maxBackoffSeconds, base + jitter)
    }

    private func recordLifecycleEvent(store: SQLiteStateStore, type: String, severity: StateEventSeverity, message: String) throws {
        let timestamp = clock.timestamp()
        try store.events.append([
            EventRecord(
                id: idGenerator("event-daemon"),
                timestamp: timestamp,
                severity: severity,
                type: type,
                source: "hostwrightd",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: message,
                payloadJSONRedacted: payload(["mode": configuration.mode.rawValue])
            )
        ])
    }

    private func recordLifecycleEventIfStateAvailable(
        store: SQLiteStateStore,
        type: String,
        severity: StateEventSeverity,
        message: String
    ) throws -> Bool {
        do {
            try recordLifecycleEvent(
                store: store,
                type: type,
                severity: severity,
                message: message
            )
            return true
        } catch let error as StateStoreError where Self.isTransientStateContention(error) {
            return false
        }
    }

    private static func isTransientStateContention(_ error: StateStoreError) -> Bool {
        if case .databaseLocked = error {
            return true
        }
        return false
    }

    public static func deterministicJitter(iteration: Int, maximum: Int) -> Int {
        guard maximum > 0 else { return 0 }
        return Int(stableHash(String(iteration)).prefix(4), radix: 16).map { $0 % (maximum + 1) } ?? 0
    }
}

public final class SystemDaemonClock: DaemonClock {
    private let shutdownToken: DaemonShutdownToken
    private let configurationMonitor: DaemonConfigurationChangeMonitor?
    private let formatter = ISO8601DateFormatter()

    public init(
        shutdownToken: DaemonShutdownToken,
        configurationMonitor: DaemonConfigurationChangeMonitor? = nil
    ) {
        self.shutdownToken = shutdownToken
        self.configurationMonitor = configurationMonitor
    }

    public func timestamp() -> String {
        formatter.string(from: Date())
    }

    public func sleep(seconds: Int) async throws -> DaemonWakeReason {
        guard seconds > 0 else {
            if configurationMonitor?.consumePendingChange() == true {
                return .configurationChanged
            }
            return shutdownToken.isShutdownRequested ? .shutdownRequested : .scheduled
        }

        for _ in 0..<seconds {
            for _ in 0..<10 {
                if shutdownToken.isShutdownRequested {
                    return .shutdownRequested
                }
                if configurationMonitor?.consumePendingChange() == true {
                    return .configurationChanged
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return shutdownToken.isShutdownRequested ? .shutdownRequested : .scheduled
    }
}

private func stableHash(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func durationMilliseconds(from startedAt: String, to completedAt: String) -> Int? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    guard let start = fractional.date(from: startedAt) ?? whole.date(from: startedAt),
          let end = fractional.date(from: completedAt) ?? whole.date(from: completedAt) else {
        return nil
    }
    let milliseconds = Int(end.timeIntervalSince(start) * 1_000)
    guard (0...86_400_000).contains(milliseconds) else { return nil }
    return milliseconds
}

private func payload(_ object: [String: Any]) -> String {
    let redacted = redactJSONValue(object)
    let data = try! JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

private func jsonArray(_ values: [String]) -> String {
    let redacted = values.map { RuntimeRedactionPolicy.default.redact($0) }
    let data = try! JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

private func redactJSONValue(_ value: Any) -> Any {
    if let string = value as? String {
        return RuntimeRedactionPolicy.default.redact(string)
    }
    if let array = value as? [Any] {
        return array.map(redactJSONValue)
    }
    if let dictionary = value as? [String: Any] {
        return dictionary.mapValues(redactJSONValue)
    }
    return value
}

private func daemonDiagnostic(for error: Error) -> HostwrightDiagnostic {
    if let diagnostic = error as? HostwrightDiagnostic {
        return diagnostic
    }

    if let manifestError = error as? ManifestParseError {
        let issues = manifestError.issues
        let code = issues.first?.code ?? .manifestValidationFailed
        return HostwrightDiagnostic(
            code: code,
            message: issues.map(\.rendered).joined(separator: "; ")
        )
    }

    if let runtimeError = error as? RuntimeAdapterError {
        return HostwrightDiagnostic(code: .runtimeUnavailable, message: String(describing: runtimeError.redacted()))
    }

    if let stateError = error as? StateStoreError {
        return HostwrightDiagnostic(code: .stateStoreUnavailable, message: String(describing: stateError))
    }

    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
        return HostwrightDiagnostic(code: .manifestFileIOFailed, message: nsError.localizedDescription)
    }

    return HostwrightDiagnostic(code: .runtimeUnavailable, message: String(describing: error))
}
