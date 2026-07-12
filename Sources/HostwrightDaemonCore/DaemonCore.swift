import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

public enum DaemonMode: String, Equatable, Sendable {
    case foregroundDev = "foreground-dev"
}

public enum DaemonWakeReason: String, Equatable, Sendable {
    case scheduled
    case systemWake
    case shutdownRequested
}

public struct DaemonConfiguration: Equatable, Sendable {
    public let mode: DaemonMode
    public let configPath: String
    public let stateDatabasePath: String
    public let lockFilePath: String
    public let cadenceSeconds: Int
    public let jitterSeconds: Int
    public let maxBackoffSeconds: Int
    public let maxIterations: Int?

    public init(
        mode: DaemonMode = .foregroundDev,
        configPath: String,
        stateDatabasePath: String,
        lockFilePath: String? = nil,
        cadenceSeconds: Int = 30,
        jitterSeconds: Int = 5,
        maxBackoffSeconds: Int = 300,
        maxIterations: Int? = nil
    ) {
        self.mode = mode
        self.configPath = configPath
        self.stateDatabasePath = stateDatabasePath
        self.lockFilePath = lockFilePath ?? "\(stateDatabasePath).hostwrightd.lock"
        self.cadenceSeconds = cadenceSeconds
        self.jitterSeconds = jitterSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.maxIterations = maxIterations
    }

    public func validate() throws {
        guard !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DaemonError.invalidConfiguration("--config <path> is required.")
        }
        guard !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DaemonError.invalidConfiguration("--state-db <path> is required.")
        }
        guard !lockFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DaemonError.invalidConfiguration("lock file path must not be empty.")
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
    public var idGenerator: (String) -> String
    public var jitterProvider: (Int, Int) -> Int

    private let configuration: DaemonConfiguration
    private let runtimeAdapter: any RuntimeAdapter
    private let healthChecker: any RuntimeHealthChecking
    private let clock: any DaemonClock
    private let instanceLock: any DaemonInstanceLock
    private let shutdownToken: DaemonShutdownToken

    public init(
        configuration: DaemonConfiguration,
        runtimeAdapter: any RuntimeAdapter,
        healthChecker: any RuntimeHealthChecking = BoundedRuntimeHealthChecker(),
        clock: any DaemonClock,
        instanceLock: any DaemonInstanceLock,
        shutdownToken: DaemonShutdownToken = DaemonShutdownToken(),
        readConfig: @escaping (String) throws -> String,
        idGenerator: @escaping (String) -> String = { "\(String($0))-\(UUID().uuidString)" },
        jitterProvider: @escaping (Int, Int) -> Int = DaemonLoopRunner.deterministicJitter
    ) {
        self.configuration = configuration
        self.runtimeAdapter = runtimeAdapter
        self.healthChecker = healthChecker
        self.clock = clock
        self.instanceLock = instanceLock
        self.shutdownToken = shutdownToken
        self.readConfig = readConfig
        self.idGenerator = idGenerator
        self.jitterProvider = jitterProvider
    }

    public func run() async throws -> DaemonRunSummary {
        try configuration.validate()
        guard try instanceLock.acquire() else {
            throw DaemonError.lockUnavailable(path: configuration.lockFilePath)
        }
        defer { instanceLock.release() }

        let store = SQLiteStateStore(path: configuration.stateDatabasePath)
        try store.migrate()
        try recordLifecycleEvent(store: store, type: "daemon.started", severity: .info, message: "hostwrightd foreground dev loop started.")

        var iterations = 0
        var successfulIterations = 0
        var failedIterations = 0
        var consecutiveFailures = 0

        while !shutdownToken.isShutdownRequested {
            if let maxIterations = configuration.maxIterations, iterations >= maxIterations {
                break
            }

            iterations += 1
            let result = try await runIteration(iteration: iterations, store: store)
            switch result {
            case .success:
                successfulIterations += 1
                consecutiveFailures = 0
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
                try recordLifecycleEvent(
                    store: store,
                    type: "daemon.backoff",
                    severity: .warning,
                    message: "hostwrightd backing off for \(delay) second(s) after \(consecutiveFailures) consecutive failure(s)."
                )
            }

            let wakeReason = try await clock.sleep(seconds: delay)
            switch wakeReason {
            case .scheduled:
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
            message: stoppedByShutdown ? "hostwrightd foreground dev loop stopped after shutdown request." : "hostwrightd foreground dev loop stopped."
        )

        return DaemonRunSummary(
            iterations: iterations,
            successfulIterations: successfulIterations,
            failedIterations: failedIterations,
            stoppedByShutdown: stoppedByShutdown
        )
    }

    private enum IterationResult {
        case success
        case failure
    }

    private func runIteration(iteration: Int, store: SQLiteStateStore) async throws -> IterationResult {
        let startedAt = clock.timestamp()
        do {
            let manifestText = try readConfig(configuration.configPath)
            let manifest = try ManifestValidator.validated(manifestText)
            let mapping = ManifestRuntimeMapper.map(manifest)
            let projectID = "project-\(mapping.desiredState.projectName)"
            let observationDesiredState = DesiredRuntimeState(
                projectName: mapping.desiredState.projectName,
                services: mapping.desiredState.services,
                ownedResourceHints: try store.ownership.runtimeHints(
                    projectID: projectID,
                    projectName: mapping.desiredState.projectName
                )
            )
            let observed = try await runtimeAdapter.observe(desiredState: observationDesiredState)
            let adapterName = observed.adapterMetadata?.adapterName ?? "runtime-adapter"

            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: configuration.configPath,
                manifestHash: stableHash(manifestText),
                desiredGeneration: iteration,
                manifest: manifest,
                timestamp: startedAt
            )

            let healthResults = try await runHealthChecks(
                desiredState: mapping.desiredState,
                observedState: observed,
                store: store,
                projectID: projectID,
                timestamp: startedAt
            )
            try persistHealthResults(healthResults, store: store, projectID: projectID, checkedAt: startedAt)
            let observedWithHealth = observedState(observed, applying: healthResults)
            try upsertRestartPolicyStates(
                desiredState: mapping.desiredState,
                observedState: observedWithHealth,
                store: store,
                projectID: projectID,
                timestamp: startedAt
            )
            let restartPolicyStates = try restartPolicyStateMap(
                store: store,
                projectID: projectID,
                projectName: mapping.desiredState.projectName
            )
            let plan = ReconciliationPlanner().plan(
                manifest: manifest,
                observedState: observedWithHealth,
                restartPolicyStates: restartPolicyStates,
                currentTimestamp: startedAt
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
            try store.operations.record(
                OperationRecord(
                    id: idGenerator("operation-daemon"),
                    createdAt: startedAt,
                    updatedAt: startedAt,
                    plannedActionType: "daemon.reconcile",
                    projectID: projectID,
                    serviceName: nil,
                    status: .succeeded,
                    idempotencyKey: "daemon:\(iteration)",
                    planHash: plan.planHash,
                    payloadJSONRedacted: payload([
                        "actions": plan.actions.count,
                        "drift": plan.drift.count,
                        "healthChecks": healthResults.count,
                        "mutationAttempted": false,
                        "planHash": plan.planHash,
                        "restartPolicyBlocked": plan.issues.filter { $0.kind == .restartPolicyBlocked }.count
                    ])
                )
            )
            try store.events.append([
                EventRecord(
                    id: idGenerator("event-daemon"),
                    timestamp: startedAt,
                    severity: .info,
                    type: "daemon.reconcile.succeeded",
                    source: "hostwrightd",
                    projectID: projectID,
                    serviceName: nil,
                    runtimeAdapter: adapterName,
                    message: "Daemon reconciliation observed \(observedWithHealth.services.count) service(s), recorded \(healthResults.count) health check result(s), planned \(plan.actions.count) action(s), and attempted no runtime mutation.",
                    payloadJSONRedacted: payload([
                        "actions": plan.actions.count,
                        "drift": plan.drift.count,
                        "healthChecks": healthResults.count,
                        "mutationAttempted": false,
                        "planHash": plan.planHash,
                        "restartPolicyBlocked": plan.issues.filter { $0.kind == .restartPolicyBlocked }.count
                    ])
                )
            ])
            return .success
        } catch {
            let diagnostic = daemonDiagnostic(for: error)
            let message = RuntimeRedactionPolicy.default.redact(diagnostic.message)
            try store.operations.record(
                OperationRecord(
                    id: idGenerator("operation-daemon"),
                    createdAt: startedAt,
                    updatedAt: startedAt,
                    plannedActionType: "daemon.reconcile",
                    projectID: nil,
                    serviceName: nil,
                    status: .failed,
                    idempotencyKey: "daemon:\(iteration)",
                    planHash: "unavailable",
                    payloadJSONRedacted: payload([
                        "error": message,
                        "errorCode": diagnostic.code.rawValue,
                        "mutationAttempted": false
                    ])
                )
            )
            try store.events.append([
                EventRecord(
                    id: idGenerator("event-daemon"),
                    timestamp: startedAt,
                    severity: .error,
                    type: "daemon.reconcile.failed",
                    source: "hostwrightd",
                    projectID: nil,
                    serviceName: nil,
                    runtimeAdapter: nil,
                    message: "Daemon reconciliation failed without runtime mutation: \(diagnostic.code.rawValue): \(message)",
                    payloadJSONRedacted: payload([
                        "error": message,
                        "errorCode": diagnostic.code.rawValue,
                        "mutationAttempted": false
                    ])
                )
            ])
            return .failure
        }
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
                networks: service.networks,
                mounts: service.mounts,
                observedAt: service.observedAt
            )
        }

        return ObservedRuntimeState(
            projectName: observedState.projectName,
            services: services,
            adapterMetadata: observedState.adapterMetadata
        )
    }

    private func upsertRestartPolicyStates(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState,
        store: SQLiteStateStore,
        projectID: String,
        timestamp: String
    ) throws {
        let observedByIdentity = Dictionary(
            observedState.services.map { (normalizedIdentity($0.identity), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingStates = Dictionary(
            try store.restartPolicies.loadProject(projectID: projectID).map { ($0.serviceName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var events: [EventRecord] = []

        for desired in desiredState.services.sorted(by: { $0.identity.displayName < $1.identity.displayName }) {
            let observed = observedByIdentity[normalizedIdentity(desired.identity)]
            let previous = existingStates[desired.identity.serviceName]
            let state = restartPolicyState(
                desired: desired,
                observed: observed,
                previous: previous,
                projectID: projectID,
                timestamp: timestamp
            )
            try store.restartPolicies.upsert(state)

            events.append(
                EventRecord(
                    id: idGenerator("event-restart-policy"),
                    timestamp: timestamp,
                    severity: restartStateSeverity(state.status),
                    type: "restart.policy.state",
                    source: "hostwrightd",
                    projectID: projectID,
                    serviceName: desired.identity.serviceName,
                    runtimeAdapter: nil,
                    message: "Restart policy state for \(desired.identity.displayName) is \(state.status.rawValue); daemon attempted no runtime mutation.",
                    payloadJSONRedacted: state.metadataJSONRedacted
                )
            )
        }

        try store.events.append(events)
    }

    private func restartPolicyState(
        desired: DesiredRuntimeService,
        observed: ObservedRuntimeService?,
        previous: RestartPolicyStateRecord?,
        projectID: String,
        timestamp: String
    ) -> RestartPolicyStateRecord {
        let maxAttempts = previous?.maxAttempts ?? RestartPolicyStateDefaults.maxAttempts
        let backoffSeconds = previous?.backoffSeconds ?? RestartPolicyStateDefaults.backoffSeconds

        let status: RestartPolicyStateStatus
        let attemptCount: Int
        let backoffUntil: String?
        let lastFailureAt: String?

        if desired.restartPolicy == .no {
            status = .manualDisabled
            attemptCount = 0
            backoffUntil = nil
            lastFailureAt = nil
        } else if observed?.lifecycleState == .running && observed?.healthState == .healthy {
            status = .active
            attemptCount = 0
            backoffUntil = nil
            lastFailureAt = nil
        } else if previous?.status == .operatorHold || previous?.status == .manualDisabled || previous?.status == .crashLoopBlocked {
            status = previous?.status ?? .active
            attemptCount = previous?.attemptCount ?? 0
            backoffUntil = previous?.backoffUntil
            lastFailureAt = previous?.lastFailureAt
        } else {
            status = previous?.status ?? .active
            attemptCount = previous?.attemptCount ?? 0
            backoffUntil = previous?.backoffUntil
            lastFailureAt = previous?.lastFailureAt
        }

        return RestartPolicyStateRecord(
            id: previous?.id ?? idGenerator("restart-policy"),
            projectID: projectID,
            serviceName: desired.identity.serviceName,
            policy: desired.restartPolicy,
            status: status,
            attemptCount: attemptCount,
            maxAttempts: maxAttempts,
            backoffSeconds: backoffSeconds,
            backoffUntil: backoffUntil,
            lastFailureAt: lastFailureAt,
            updatedAt: timestamp,
            metadataJSONRedacted: payload([
                "attemptCount": attemptCount,
                "backoffUntil": backoffUntil ?? "",
                "healthState": observed?.healthState.rawValue ?? "unknown",
                "lifecycleState": observed?.lifecycleState.rawValue ?? "missing",
                "maxAttempts": maxAttempts,
                "mutationAttempted": false,
                "policy": desired.restartPolicy.rawValue,
                "status": status.rawValue
            ])
        )
    }

    private func restartPolicyStateMap(
        store: SQLiteStateStore,
        projectID: String,
        projectName: String
    ) throws -> [RuntimeServiceIdentity: RestartPolicyStateRecord] {
        Dictionary(try store.restartPolicies.loadProject(projectID: projectID).map { state in
            (
                RuntimeServiceIdentity(projectName: projectName, serviceName: state.serviceName),
                state
            )
        }, uniquingKeysWith: { first, _ in first })
    }

    private func normalizedIdentity(_ identity: RuntimeServiceIdentity) -> RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: identity.projectName, serviceName: identity.serviceName)
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
        case .active:
            return .info
        case .backingOff, .operatorHold, .manualDisabled:
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

    public static func deterministicJitter(iteration: Int, maximum: Int) -> Int {
        guard maximum > 0 else { return 0 }
        return Int(stableHash(String(iteration)).prefix(4), radix: 16).map { $0 % (maximum + 1) } ?? 0
    }
}

public final class SystemDaemonClock: DaemonClock {
    private let shutdownToken: DaemonShutdownToken
    private let formatter = ISO8601DateFormatter()

    public init(shutdownToken: DaemonShutdownToken) {
        self.shutdownToken = shutdownToken
    }

    public func timestamp() -> String {
        formatter.string(from: Date())
    }

    public func sleep(seconds: Int) async throws -> DaemonWakeReason {
        guard seconds > 0 else {
            return shutdownToken.isShutdownRequested ? .shutdownRequested : .scheduled
        }

        for _ in 0..<seconds {
            if shutdownToken.isShutdownRequested {
                return .shutdownRequested
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
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
