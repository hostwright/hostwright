import Foundation
import HostwrightManifest
import HostwrightRuntime
import HostwrightState

public struct RuntimeProbeActionCapability: Codable, Equatable, Sendable {
    public let action: RuntimeProbeActionKind
    public let state: RuntimeProviderCapabilityState
    public let reason: RuntimeProviderFeatureReason

    public init(
        action: RuntimeProbeActionKind,
        state: RuntimeProviderCapabilityState,
        reason: RuntimeProviderFeatureReason
    ) {
        self.action = action
        self.state = state
        self.reason = reason
    }
}

public struct RuntimeProbeCapabilities: Codable, Equatable, Sendable {
    public let providerID: RuntimeProviderID?
    public let actions: [RuntimeProbeActionCapability]

    public init(
        providerID: RuntimeProviderID? = nil,
        actions: [RuntimeProbeActionCapability]
    ) {
        self.providerID = providerID
        self.actions = actions.sorted { $0.action.rawValue < $1.action.rawValue }
    }

    public static func allAvailable(
        for providerID: RuntimeProviderID? = nil
    ) -> RuntimeProbeCapabilities {
        RuntimeProbeCapabilities(
            providerID: providerID,
            actions: RuntimeProbeActionKind.allCases.map {
                RuntimeProbeActionCapability(
                    action: $0,
                    state: .available,
                    reason: .implemented
                )
            }
        )
    }

    public static func allUnavailable(
        for providerID: RuntimeProviderID? = nil,
        reason: RuntimeProviderFeatureReason = .notImplemented
    ) -> RuntimeProbeCapabilities {
        RuntimeProbeCapabilities(
            providerID: providerID,
            actions: RuntimeProbeActionKind.allCases.map {
                RuntimeProbeActionCapability(
                    action: $0,
                    state: .unavailable,
                    reason: reason
                )
            }
        )
    }

    public static func qualified(
        for providerID: RuntimeProviderID,
        _ qualifiedActions: Set<RuntimeProbeActionKind>
    ) -> RuntimeProbeCapabilities {
        RuntimeProbeCapabilities(
            providerID: providerID,
            actions: RuntimeProbeActionKind.allCases.map { action in
                let isQualified = qualifiedActions.contains(action)
                return RuntimeProbeActionCapability(
                    action: action,
                    state: isQualified ? .available : .unavailable,
                    reason: isQualified ? .implemented : .qualificationIncomplete
                )
            }
        )
    }

    public func status(for action: RuntimeProbeActionKind) -> RuntimeProbeActionCapability? {
        actions.first { $0.action == action }
    }
}

public enum RuntimeProbeManifestMapper {
    public static func map(_ probes: HostwrightProbes) -> RuntimeProbeSet {
        RuntimeProbeSet(
            startup: probes.startup.map(map),
            readiness: probes.readiness.map(map),
            liveness: probes.liveness.map(map)
        )
    }

    private static func map(_ probe: HostwrightProbe) -> RuntimeProbeConfiguration {
        RuntimeProbeConfiguration(
            action: map(probe.action),
            startPeriodSeconds: probe.startPeriod,
            intervalSeconds: probe.interval,
            timeoutSeconds: probe.timeout,
            successThreshold: probe.successThreshold,
            failureThreshold: probe.failureThreshold
        )
    }

    private static func map(_ action: HostwrightProbeAction) -> RuntimeProbeAction {
        switch action {
        case .exec(let command):
            .exec(RuntimeProbeExecAction(command: command))
        case .http(let port, let path):
            .http(RuntimeProbeHTTPAction(port: port, path: path))
        case .tcp(let port):
            .tcp(RuntimeProbeTCPAction(port: port))
        }
    }
}

public enum RuntimeProbeValidationError: Error, Equatable, Sendable {
    case duplicateCapability(RuntimeProbeActionKind)
    case missingCapability(RuntimeProbeActionKind)
    case capabilityUnavailable(
        action: RuntimeProbeActionKind,
        state: RuntimeProviderCapabilityState,
        reason: RuntimeProviderFeatureReason
    )
    case emptyExecCommand
    case tooManyExecArguments
    case execCommandTooLarge
    case invalidExecArgument
    case invalidPort(Int)
    case undeclaredPort(Int)
    case invalidHTTPPath
    case invalidStartPeriod(Int)
    case invalidInterval(Int)
    case invalidTimeout(Int)
    case invalidSuccessThreshold(Int)
    case invalidFailureThreshold(Int)
    case invalidSnapshot
    case staleAttempt
    case redirectLimitExceeded
    case redirectNotLoopback
    case redirectChangedOrigin
}

public enum RuntimeProbeValidator {
    public static let maximumExecArguments = 128
    public static let maximumExecCommandBytes = 16 * 1_024
    public static let maximumHTTPPathBytes = 2_048
    public static let maximumStartPeriodSeconds = 86_400
    public static let maximumIntervalSeconds = 86_400
    public static let maximumTimeoutSeconds = 30
    public static let maximumThreshold = 100

    public static func validate(
        _ probes: RuntimeProbeSet,
        declaredPorts: [RuntimePortMapping],
        capabilities: RuntimeProbeCapabilities
    ) throws {
        try validate(
            probes,
            declaredContainerPorts: Set(declaredPorts.map(\.containerPort)),
            capabilities: capabilities
        )
    }

    public static func validate(
        _ probes: RuntimeProbeSet,
        declaredContainerPorts: Set<Int>,
        capabilities: RuntimeProbeCapabilities
    ) throws {
        let groupedCapabilities = Dictionary(grouping: capabilities.actions, by: \.action)
        for action in RuntimeProbeActionKind.allCases {
            guard let statuses = groupedCapabilities[action] else {
                throw RuntimeProbeValidationError.missingCapability(action)
            }
            guard statuses.count == 1 else {
                throw RuntimeProbeValidationError.duplicateCapability(action)
            }
        }

        for kind in probes.configuredKinds {
            guard let configuration = probes[kind] else {
                continue
            }
            guard let status = capabilities.status(for: configuration.action.kind) else {
                throw RuntimeProbeValidationError.missingCapability(configuration.action.kind)
            }
            guard status.state == .available else {
                throw RuntimeProbeValidationError.capabilityUnavailable(
                    action: status.action,
                    state: status.state,
                    reason: status.reason
                )
            }
            try validate(configuration, declaredContainerPorts: declaredContainerPorts)
        }
    }

    public static func validate(
        _ configuration: RuntimeProbeConfiguration,
        declaredContainerPorts: Set<Int>
    ) throws {
        guard (0 ... maximumStartPeriodSeconds).contains(configuration.startPeriodSeconds) else {
            throw RuntimeProbeValidationError.invalidStartPeriod(configuration.startPeriodSeconds)
        }
        guard (1 ... maximumIntervalSeconds).contains(configuration.intervalSeconds) else {
            throw RuntimeProbeValidationError.invalidInterval(configuration.intervalSeconds)
        }
        guard (1 ... maximumTimeoutSeconds).contains(configuration.timeoutSeconds) else {
            throw RuntimeProbeValidationError.invalidTimeout(configuration.timeoutSeconds)
        }
        guard (1 ... maximumThreshold).contains(configuration.successThreshold) else {
            throw RuntimeProbeValidationError.invalidSuccessThreshold(
                configuration.successThreshold
            )
        }
        guard (1 ... maximumThreshold).contains(configuration.failureThreshold) else {
            throw RuntimeProbeValidationError.invalidFailureThreshold(
                configuration.failureThreshold
            )
        }

        switch configuration.action {
        case .exec(let action):
            guard !action.command.isEmpty else {
                throw RuntimeProbeValidationError.emptyExecCommand
            }
            guard action.command.count <= maximumExecArguments else {
                throw RuntimeProbeValidationError.tooManyExecArguments
            }
            guard action.command.allSatisfy({
                !$0.isEmpty && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r")
            }) else {
                throw RuntimeProbeValidationError.invalidExecArgument
            }
            guard action.command.reduce(0, { $0 + $1.utf8.count }) <= maximumExecCommandBytes else {
                throw RuntimeProbeValidationError.execCommandTooLarge
            }
        case .http(let action):
            try validatePort(action.port, declaredContainerPorts: declaredContainerPorts)
            guard action.path.hasPrefix("/"),
                  !action.path.contains("://"),
                  !action.path.contains("\0"),
                  !action.path.contains("\r"),
                  !action.path.contains("\n"),
                  action.path.utf8.count <= maximumHTTPPathBytes,
                  action.implicitLoopbackURL != nil else {
                throw RuntimeProbeValidationError.invalidHTTPPath
            }
        case .tcp(let action):
            try validatePort(action.port, declaredContainerPorts: declaredContainerPorts)
        }
    }

    private static func validatePort(
        _ port: Int,
        declaredContainerPorts: Set<Int>
    ) throws {
        guard (1 ... 65_535).contains(port) else {
            throw RuntimeProbeValidationError.invalidPort(port)
        }
        guard declaredContainerPorts.contains(port) else {
            throw RuntimeProbeValidationError.undeclaredPort(port)
        }
    }
}

public enum RuntimeProbeAttemptOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case timedOut = "timed-out"
    case cancelled
    case unavailable

    fileprivate var countsAsFailure: Bool {
        self == .failed || self == .timedOut
    }
}

public struct RuntimeProbeAttemptResult: Codable, Equatable, Sendable {
    public static let maximumDiagnosticBytes = 4_096

    public let outcome: RuntimeProbeAttemptOutcome
    public let completedAtMilliseconds: Int64
    public let diagnosticRedacted: String

    public init(
        outcome: RuntimeProbeAttemptOutcome,
        completedAtMilliseconds: Int64,
        diagnosticRedacted: String = ""
    ) {
        self.outcome = outcome
        self.completedAtMilliseconds = completedAtMilliseconds
        self.diagnosticRedacted = Self.bounded(
            diagnosticRedacted,
            maximumBytes: Self.maximumDiagnosticBytes
        )
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else {
            return value
        }

        var bytes = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let count = value[end ..< next].utf8.count
            guard bytes + count <= maximumBytes else {
                break
            }
            bytes += count
            end = next
        }
        return String(value[..<end])
    }
}

public enum RuntimeProbePhase: String, Codable, Equatable, Sendable {
    case waiting
    case executing
    case succeeding
    case failing
    case succeeded
    case failed
    case unavailable
}

public struct RuntimeProbeState: Codable, Equatable, Sendable {
    public let kind: RuntimeProbeKind
    public let phase: RuntimeProbePhase
    public let isPassing: Bool
    public let consecutiveSuccesses: Int
    public let consecutiveFailures: Int
    public let attemptCount: Int
    public let inFlightAttempt: Int?
    public let nextAttemptAtMilliseconds: Int64
    public let lastAttemptAtMilliseconds: Int64?
    public let lastOutcome: RuntimeProbeAttemptOutcome?
    public let lastDiagnosticRedacted: String

    public init(
        kind: RuntimeProbeKind,
        phase: RuntimeProbePhase,
        isPassing: Bool = false,
        consecutiveSuccesses: Int = 0,
        consecutiveFailures: Int = 0,
        attemptCount: Int = 0,
        inFlightAttempt: Int? = nil,
        nextAttemptAtMilliseconds: Int64,
        lastAttemptAtMilliseconds: Int64? = nil,
        lastOutcome: RuntimeProbeAttemptOutcome? = nil,
        lastDiagnosticRedacted: String = ""
    ) {
        self.kind = kind
        self.phase = phase
        self.isPassing = isPassing
        self.consecutiveSuccesses = consecutiveSuccesses
        self.consecutiveFailures = consecutiveFailures
        self.attemptCount = attemptCount
        self.inFlightAttempt = inFlightAttempt
        self.nextAttemptAtMilliseconds = nextAttemptAtMilliseconds
        self.lastAttemptAtMilliseconds = lastAttemptAtMilliseconds
        self.lastOutcome = lastOutcome
        self.lastDiagnosticRedacted = lastDiagnosticRedacted
    }
}

public struct RuntimeProbeSnapshot: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let startedAtMilliseconds: Int64
    public let states: [RuntimeProbeState]

    public init(
        resourceIdentifier: String,
        startedAtMilliseconds: Int64,
        states: [RuntimeProbeState]
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.startedAtMilliseconds = startedAtMilliseconds
        self.states = states.sorted { $0.kind.order < $1.kind.order }
    }

    public func state(for kind: RuntimeProbeKind) -> RuntimeProbeState? {
        states.first { $0.kind == kind }
    }
}

public struct RuntimeProbeExecutionRequest: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let kind: RuntimeProbeKind
    public let attempt: Int
    public let action: RuntimeProbeAction
    public let timeoutSeconds: Int

    public init(
        resourceIdentifier: String,
        kind: RuntimeProbeKind,
        attempt: Int,
        action: RuntimeProbeAction,
        timeoutSeconds: Int
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.kind = kind
        self.attempt = attempt
        self.action = action
        self.timeoutSeconds = timeoutSeconds
    }
}

public protocol RuntimeProbeExecuting: Sendable {
    func executeProbe(_ request: RuntimeProbeExecutionRequest) async -> RuntimeProbeAttemptResult
}

public enum RuntimeProbeDirective: Equatable, Sendable {
    case execute(RuntimeProbeExecutionRequest)
    case wait(untilMilliseconds: Int64)
    case gated(by: RuntimeProbeKind)
    case terminalFailure(RuntimeProbeKind)
    case complete
}

public enum RuntimeProbeReadiness: String, Codable, Equatable, Sendable {
    case ready
    case notReady = "not-ready"
    case gated
}

public enum RuntimeProbeLiveness: String, Codable, Equatable, Sendable {
    case healthy
    case unhealthy
    case unavailable
    case gated
}

public enum RuntimeProbeStateMachine {
    public static func initialSnapshot(
        resourceIdentifier: String,
        probes: RuntimeProbeSet,
        startedAtMilliseconds: Int64
    ) -> RuntimeProbeSnapshot {
        RuntimeProbeSnapshot(
            resourceIdentifier: resourceIdentifier,
            startedAtMilliseconds: startedAtMilliseconds,
            states: probes.configuredKinds.compactMap { kind in
                guard let configuration = probes[kind] else {
                    return nil
                }
                return RuntimeProbeState(
                    kind: kind,
                    phase: .waiting,
                    nextAttemptAtMilliseconds: startedAtMilliseconds +
                        milliseconds(configuration.startPeriodSeconds)
                )
            }
        )
    }

    public static func nextDirective(
        probes: RuntimeProbeSet,
        snapshot: RuntimeProbeSnapshot,
        nowMilliseconds: Int64
    ) throws -> RuntimeProbeDirective {
        try validate(snapshot: snapshot, probes: probes)

        if probes.startup != nil {
            guard let startup = snapshot.state(for: .startup) else {
                throw RuntimeProbeValidationError.invalidSnapshot
            }
            if startup.phase == .failed || startup.phase == .unavailable {
                return .terminalFailure(.startup)
            }
            if startup.phase != .succeeded {
                return try directive(
                    for: .startup,
                    configuration: probes.startup,
                    snapshot: snapshot,
                    nowMilliseconds: nowMilliseconds
                )
            }
        }

        for kind in [RuntimeProbeKind.readiness, .liveness] {
            guard let configuration = probes[kind] else {
                continue
            }
            let decision = try directive(
                for: kind,
                configuration: configuration,
                snapshot: snapshot,
                nowMilliseconds: nowMilliseconds
            )
            if case .wait = decision {
                continue
            }
            return decision
        }

        let nextWake = snapshot.states
            .filter { $0.kind != .startup || $0.phase != .succeeded }
            .map(\.nextAttemptAtMilliseconds)
            .min()
        return nextWake.map { .wait(untilMilliseconds: $0) } ?? .complete
    }

    public static func markAttemptStarted(
        kind: RuntimeProbeKind,
        probes: RuntimeProbeSet,
        snapshot: RuntimeProbeSnapshot,
        nowMilliseconds: Int64
    ) throws -> (snapshot: RuntimeProbeSnapshot, request: RuntimeProbeExecutionRequest) {
        try validate(snapshot: snapshot, probes: probes)
        if kind != .startup,
           probes.startup != nil,
           snapshot.state(for: .startup)?.phase != .succeeded {
            throw RuntimeProbeValidationError.invalidSnapshot
        }
        guard let configuration = probes[kind],
              let current = snapshot.state(for: kind),
              current.phase != .executing,
              current.phase != .unavailable,
              !(kind == .startup && (current.phase == .succeeded || current.phase == .failed)),
              nowMilliseconds >= current.nextAttemptAtMilliseconds else {
            throw RuntimeProbeValidationError.invalidSnapshot
        }

        let attempt = current.attemptCount + 1
        let updated = RuntimeProbeState(
            kind: kind,
            phase: .executing,
            isPassing: current.isPassing,
            consecutiveSuccesses: current.consecutiveSuccesses,
            consecutiveFailures: current.consecutiveFailures,
            attemptCount: attempt,
            inFlightAttempt: attempt,
            nextAttemptAtMilliseconds: current.nextAttemptAtMilliseconds,
            lastAttemptAtMilliseconds: nowMilliseconds,
            lastOutcome: current.lastOutcome,
            lastDiagnosticRedacted: current.lastDiagnosticRedacted
        )
        let nextSnapshot = replacing(updated, in: snapshot)
        return (
            nextSnapshot,
            RuntimeProbeExecutionRequest(
                resourceIdentifier: snapshot.resourceIdentifier,
                kind: kind,
                attempt: attempt,
                action: configuration.action,
                timeoutSeconds: configuration.timeoutSeconds
            )
        )
    }

    public static func record(
        _ result: RuntimeProbeAttemptResult,
        request: RuntimeProbeExecutionRequest,
        probes: RuntimeProbeSet,
        snapshot: RuntimeProbeSnapshot
    ) throws -> RuntimeProbeSnapshot {
        try validate(snapshot: snapshot, probes: probes)
        guard request.resourceIdentifier == snapshot.resourceIdentifier,
              let configuration = probes[request.kind],
              let current = snapshot.state(for: request.kind),
              current.phase == .executing,
              current.inFlightAttempt == request.attempt,
              request.action == configuration.action,
              request.timeoutSeconds == configuration.timeoutSeconds,
              result.completedAtMilliseconds >=
                  (current.lastAttemptAtMilliseconds ?? result.completedAtMilliseconds) else {
            throw RuntimeProbeValidationError.staleAttempt
        }

        let phase: RuntimeProbePhase
        let isPassing: Bool
        let successes: Int
        let failures: Int
        switch result.outcome {
        case .succeeded:
            successes = current.consecutiveSuccesses + 1
            failures = 0
            if successes >= configuration.successThreshold {
                isPassing = true
                phase = .succeeded
            } else {
                isPassing = current.isPassing
                phase = current.isPassing ? .succeeded : .succeeding
            }
        case .failed, .timedOut:
            successes = 0
            failures = current.consecutiveFailures + 1
            if failures >= configuration.failureThreshold {
                isPassing = false
                phase = .failed
            } else {
                isPassing = current.isPassing
                phase = current.isPassing ? .succeeded : .failing
            }
        case .cancelled:
            isPassing = current.isPassing
            successes = current.consecutiveSuccesses
            failures = current.consecutiveFailures
            phase = stablePhase(current, configuration: configuration)
        case .unavailable:
            isPassing = false
            successes = current.consecutiveSuccesses
            failures = current.consecutiveFailures
            phase = .unavailable
        }

        return replacing(
            RuntimeProbeState(
                kind: request.kind,
                phase: phase,
                isPassing: isPassing,
                consecutiveSuccesses: successes,
                consecutiveFailures: failures,
                attemptCount: current.attemptCount,
                inFlightAttempt: nil,
                nextAttemptAtMilliseconds: result.completedAtMilliseconds +
                    milliseconds(configuration.intervalSeconds),
                lastAttemptAtMilliseconds: current.lastAttemptAtMilliseconds,
                lastOutcome: result.outcome,
                lastDiagnosticRedacted: result.diagnosticRedacted
            ),
            in: snapshot
        )
    }

    public static func resumed(
        _ snapshot: RuntimeProbeSnapshot,
        probes: RuntimeProbeSet,
        nowMilliseconds: Int64
    ) throws -> RuntimeProbeSnapshot {
        try validate(snapshot: snapshot, probes: probes)
        return RuntimeProbeSnapshot(
            resourceIdentifier: snapshot.resourceIdentifier,
            startedAtMilliseconds: snapshot.startedAtMilliseconds,
            states: snapshot.states.map { state in
                guard state.phase == .executing else {
                    return state
                }
                guard let configuration = probes[state.kind] else {
                    return state
                }
                return RuntimeProbeState(
                    kind: state.kind,
                    phase: stablePhase(state, configuration: configuration),
                    isPassing: state.isPassing,
                    consecutiveSuccesses: state.consecutiveSuccesses,
                    consecutiveFailures: state.consecutiveFailures,
                    attemptCount: state.attemptCount,
                    inFlightAttempt: nil,
                    nextAttemptAtMilliseconds: nowMilliseconds,
                    lastAttemptAtMilliseconds: state.lastAttemptAtMilliseconds,
                    lastOutcome: state.lastOutcome,
                    lastDiagnosticRedacted: state.lastDiagnosticRedacted
                )
            }
        )
    }

    public static func readiness(
        probes: RuntimeProbeSet,
        snapshot: RuntimeProbeSnapshot
    ) -> RuntimeProbeReadiness {
        if probes.startup != nil, snapshot.state(for: .startup)?.phase != .succeeded {
            return .gated
        }
        guard probes.readiness != nil else {
            return .ready
        }
        return snapshot.state(for: .readiness)?.phase == .succeeded ? .ready : .notReady
    }

    public static func liveness(
        probes: RuntimeProbeSet,
        snapshot: RuntimeProbeSnapshot
    ) -> RuntimeProbeLiveness {
        if probes.startup != nil, snapshot.state(for: .startup)?.phase != .succeeded {
            return .gated
        }
        guard probes.liveness != nil else {
            return .healthy
        }
        switch snapshot.state(for: .liveness)?.phase {
        case .failed:
            return .unhealthy
        case .unavailable:
            return .unavailable
        default:
            return .healthy
        }
    }

    public static func livenessRestartDecision(
        probes: RuntimeProbeSet,
        snapshot: RuntimeProbeSnapshot,
        desired: DesiredRuntimeService,
        restartState: RestartPolicyStateRecord?,
        currentTimestamp: String?
    ) -> RestartPolicyDecision? {
        guard liveness(probes: probes, snapshot: snapshot) == .unhealthy else {
            return nil
        }
        return RestartPolicyEvaluator.restartDecision(
            desired: desired,
            state: restartState,
            currentTimestamp: currentTimestamp
        )
    }

    private static func directive(
        for kind: RuntimeProbeKind,
        configuration: RuntimeProbeConfiguration?,
        snapshot: RuntimeProbeSnapshot,
        nowMilliseconds: Int64
    ) throws -> RuntimeProbeDirective {
        guard let configuration, let state = snapshot.state(for: kind) else {
            throw RuntimeProbeValidationError.invalidSnapshot
        }
        if state.phase == .executing {
            let startedAt = state.lastAttemptAtMilliseconds ?? nowMilliseconds
            return .wait(
                untilMilliseconds: startedAt + milliseconds(configuration.timeoutSeconds)
            )
        }
        if state.phase == .unavailable {
            return .terminalFailure(kind)
        }
        if kind == .startup, state.phase == .failed {
            return .terminalFailure(kind)
        }
        guard nowMilliseconds >= state.nextAttemptAtMilliseconds else {
            return .wait(untilMilliseconds: state.nextAttemptAtMilliseconds)
        }
        return .execute(
            RuntimeProbeExecutionRequest(
                resourceIdentifier: snapshot.resourceIdentifier,
                kind: kind,
                attempt: state.attemptCount + 1,
                action: configuration.action,
                timeoutSeconds: configuration.timeoutSeconds
            )
        )
    }

    private static func validate(
        snapshot: RuntimeProbeSnapshot,
        probes: RuntimeProbeSet
    ) throws {
        let kinds = snapshot.states.map(\.kind)
        guard !snapshot.resourceIdentifier.isEmpty,
              Set(kinds).count == kinds.count,
              Set(kinds) == Set(probes.configuredKinds),
              snapshot.states.allSatisfy({
                  $0.consecutiveSuccesses >= 0 &&
                      $0.consecutiveFailures >= 0 &&
                      $0.attemptCount >= 0 &&
                      ($0.inFlightAttempt == nil || $0.inFlightAttempt == $0.attemptCount)
              }) else {
            throw RuntimeProbeValidationError.invalidSnapshot
        }
    }

    private static func replacing(
        _ state: RuntimeProbeState,
        in snapshot: RuntimeProbeSnapshot
    ) -> RuntimeProbeSnapshot {
        RuntimeProbeSnapshot(
            resourceIdentifier: snapshot.resourceIdentifier,
            startedAtMilliseconds: snapshot.startedAtMilliseconds,
            states: snapshot.states.map { $0.kind == state.kind ? state : $0 }
        )
    }

    private static func stablePhase(
        _ state: RuntimeProbeState,
        configuration: RuntimeProbeConfiguration
    ) -> RuntimeProbePhase {
        if state.consecutiveSuccesses >= configuration.successThreshold {
            return .succeeded
        }
        if state.consecutiveFailures >= configuration.failureThreshold {
            return .failed
        }
        if state.isPassing {
            return .succeeded
        }
        if state.consecutiveSuccesses > 0 {
            return .succeeding
        }
        if state.consecutiveFailures > 0 {
            return .failing
        }
        return .waiting
    }

    private static func milliseconds(_ seconds: Int) -> Int64 {
        Int64(seconds) * 1_000
    }
}

public enum RuntimeProbeRedirectPolicy {
    public static let maximumRedirects = 3

    public static func validate(
        originalURL: URL,
        proposedURL: URL,
        redirectsFollowed: Int
    ) throws -> URL {
        guard redirectsFollowed < maximumRedirects else {
            throw RuntimeProbeValidationError.redirectLimitExceeded
        }
        guard let original = components(for: originalURL),
              let proposed = components(for: proposedURL),
              isLoopback(original.host),
              isLoopback(proposed.host) else {
            throw RuntimeProbeValidationError.redirectNotLoopback
        }
        guard original.scheme == proposed.scheme,
              original.host == proposed.host,
              effectivePort(original) == effectivePort(proposed) else {
            throw RuntimeProbeValidationError.redirectChangedOrigin
        }
        return proposedURL
    }

    private static func components(for url: URL) -> URLComponents? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.host != nil else {
            return nil
        }
        return components
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port {
            return port
        }
        return components.scheme?.lowercased() == "https" ? 443 : 80
    }
}
