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
    private let clock: any DaemonClock
    private let instanceLock: any DaemonInstanceLock
    private let shutdownToken: DaemonShutdownToken

    public init(
        configuration: DaemonConfiguration,
        runtimeAdapter: any RuntimeAdapter,
        clock: any DaemonClock,
        instanceLock: any DaemonInstanceLock,
        shutdownToken: DaemonShutdownToken = DaemonShutdownToken(),
        readConfig: @escaping (String) throws -> String,
        idGenerator: @escaping (String) -> String = { "\(String($0))-\(UUID().uuidString)" },
        jitterProvider: @escaping (Int, Int) -> Int = DaemonLoopRunner.deterministicJitter
    ) {
        self.configuration = configuration
        self.runtimeAdapter = runtimeAdapter
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
            let observed = try await runtimeAdapter.observe(desiredState: mapping.desiredState)
            let plan = ReconciliationPlanner().plan(manifest: manifest, observedState: observed)
            let projectID = "project-\(plan.projectName)"
            let adapterName = observed.adapterMetadata?.adapterName ?? "runtime-adapter"

            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: configuration.configPath,
                manifestHash: stableHash(manifestText),
                desiredGeneration: iteration,
                manifest: manifest,
                timestamp: startedAt
            )
            try store.observedStates.saveSnapshot(
                snapshotID: idGenerator("daemon-snapshot"),
                projectID: projectID,
                observedState: observed,
                runtimeAdapter: adapterName,
                parserVersion: "daemon-observation-v1",
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
                        "mutationAttempted": false,
                        "planHash": plan.planHash
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
                    message: "Daemon reconciliation observed \(observed.services.count) service(s), planned \(plan.actions.count) action(s), and attempted no runtime mutation.",
                    payloadJSONRedacted: payload([
                        "actions": plan.actions.count,
                        "drift": plan.drift.count,
                        "mutationAttempted": false,
                        "planHash": plan.planHash
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
    let redacted = object.mapValues { value -> Any in
        if let string = value as? String {
            return RuntimeRedactionPolicy.default.redact(string)
        }
        return value
    }
    let data = try! JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
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
