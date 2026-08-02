import CryptoKit
import Foundation
import HostwrightManifest
import HostwrightRuntime
import HostwrightState

public struct RestartBudgetPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let windowSeconds: Int
    public let initialBackoffSeconds: Int
    public let maximumBackoffSeconds: Int
    public let jitterSeconds: Int
    public let stableRunSeconds: Int
    public let priority: Int
    public let projectMaxAttempts: Int
    public let projectWindowSeconds: Int

    public init(
        service: HostwrightRestart?,
        project: HostwrightProjectRestartBudget?
    ) {
        maxAttempts = service?.maxAttempts ?? RestartPolicyStateDefaults.maxAttempts
        windowSeconds = service?.window ?? RestartPolicyStateDefaults.windowSeconds
        initialBackoffSeconds = service?.backoff ?? RestartPolicyStateDefaults.backoffSeconds
        maximumBackoffSeconds = service?.maxBackoff ?? RestartPolicyStateDefaults.maximumBackoffSeconds
        jitterSeconds = service?.jitter ?? RestartPolicyStateDefaults.jitterSeconds
        stableRunSeconds = service?.stableRun ?? RestartPolicyStateDefaults.stableRunSeconds
        priority = service?.priority ?? RestartPolicyStateDefaults.priority
        projectMaxAttempts = project?.maxAttempts ?? RestartPolicyStateDefaults.projectMaxAttempts
        projectWindowSeconds = project?.window ?? RestartPolicyStateDefaults.projectWindowSeconds
    }

    public var sha256: String {
        let value = [
            maxAttempts, windowSeconds, initialBackoffSeconds,
            maximumBackoffSeconds, jitterSeconds, stableRunSeconds,
            priority, projectMaxAttempts, projectWindowSeconds
        ].map(String.init).joined(separator: "|")
        return SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

public struct RestartBudgetAttemptResult: Equatable, Sendable {
    public let state: RestartPolicyStateRecord
    public let history: RestartAttemptHistoryRecord
}

public struct RestartPolicyDecision: Equatable, Sendable {
    public let executionAvailability: PlanExecutionAvailability
    public let reason: String
    public let isBlocked: Bool

    public init(executionAvailability: PlanExecutionAvailability, reason: String, isBlocked: Bool) {
        self.executionAvailability = executionAvailability
        self.reason = reason
        self.isBlocked = isBlocked
    }
}

public enum RestartPolicyEvaluator {
    public static func preparedState(
        id: String,
        projectID: String,
        serviceName: String,
        restartPolicy: RuntimeRestartPolicy,
        policy: RestartBudgetPolicy,
        observedLifecycle: RuntimeLifecycleState?,
        observedHealth: RuntimeHealthState?,
        dependencyUnavailable: Bool = false,
        previous: RestartPolicyStateRecord?,
        projectCapacityAvailable: Bool,
        timestamp: String
    ) -> RestartPolicyStateRecord {
        let now = date(timestamp)
        var attemptCount = previous?.attemptCount ?? 0
        var windowStartedAt = previous?.windowStartedAt
        var stableSince = previous?.stableSince
        var status = previous?.status ?? .active
        var backoffUntil = previous?.backoffUntil
        var lastFailureAt = previous?.lastFailureAt
        var reasonClass = previous?.reasonClass ?? .unknown
        var holdToken = previous?.holdToken
        let releaseGeneration = previous?.releaseGeneration ?? 0

        if restartPolicy == .no {
            status = .manualDisabled
            attemptCount = 0
            windowStartedAt = nil
            stableSince = nil
            backoffUntil = nil
            lastFailureAt = nil
            holdToken = nil
        } else if previous?.status == .operatorHold || previous?.status == .crashLoopBlocked {
            status = previous?.status ?? .operatorHold
        } else if observedLifecycle == .running && observedHealth == .healthy {
            if attemptCount == 0 {
                status = .active
                stableSince = nil
                backoffUntil = nil
            } else {
                let start = stableSince ?? timestamp
                stableSince = start
                if let now, let started = date(start),
                   now.timeIntervalSince(started) >= TimeInterval(policy.stableRunSeconds) {
                    status = .active
                    attemptCount = 0
                    windowStartedAt = nil
                    stableSince = nil
                    backoffUntil = nil
                    lastFailureAt = nil
                    holdToken = nil
                } else {
                    status = .stablePending
                }
            }
        } else {
            reasonClass = dependencyUnavailable
                ? .dependencyFailure
                : classify(lifecycle: observedLifecycle, health: observedHealth)
            stableSince = nil
            if let now, let existingWindowStart = windowStartedAt,
               let windowStart = date(existingWindowStart),
               now.timeIntervalSince(windowStart) >= TimeInterval(policy.windowSeconds) {
                attemptCount = 0
                selfReset(&backoffUntil, &lastFailureAt, &holdToken)
                status = .active
                windowStartedAt = nil
            }
            if attemptCount >= policy.maxAttempts {
                status = .crashLoopBlocked
                holdToken = makeHoldToken(
                    projectID: projectID,
                    serviceName: serviceName,
                    attemptCount: attemptCount,
                    windowStartedAt: windowStartedAt,
                    releaseGeneration: releaseGeneration,
                    policySHA256: policy.sha256
                )
            } else if let now, let backoffUntil, let until = date(backoffUntil), now < until {
                status = .backingOff
            } else if !projectCapacityAvailable {
                status = .projectBudgetBlocked
                backoffUntil = nil
            } else {
                status = .active
                backoffUntil = nil
                holdToken = nil
            }
        }

        return RestartPolicyStateRecord(
            id: previous?.id ?? id,
            projectID: projectID,
            serviceName: serviceName,
            policy: restartPolicy,
            status: status,
            attemptCount: attemptCount,
            maxAttempts: policy.maxAttempts,
            backoffSeconds: previous?.backoffSeconds ?? policy.initialBackoffSeconds,
            backoffUntil: backoffUntil,
            lastFailureAt: lastFailureAt,
            reasonClass: reasonClass,
            windowStartedAt: windowStartedAt,
            windowSeconds: policy.windowSeconds,
            initialBackoffSeconds: policy.initialBackoffSeconds,
            maximumBackoffSeconds: policy.maximumBackoffSeconds,
            jitterSeconds: policy.jitterSeconds,
            stableRunSeconds: policy.stableRunSeconds,
            stableSince: stableSince,
            priority: policy.priority,
            projectMaxAttempts: policy.projectMaxAttempts,
            projectWindowSeconds: policy.projectWindowSeconds,
            holdToken: holdToken,
            releaseGeneration: releaseGeneration,
            policySHA256: policy.sha256,
            updatedAt: timestamp,
            metadataJSONRedacted: metadata(
                attemptCount: attemptCount,
                reason: reasonClass,
                status: status
            )
        )
    }

    public static func admittedAttempt(
        state: RestartPolicyStateRecord,
        projectAttemptNumber: Int,
        operationID: String?,
        failed: Bool,
        reasonOverride: RestartReasonClass? = nil,
        timestamp: String,
        historyID: String
    ) -> RestartBudgetAttemptResult {
        let attempt = state.attemptCount + 1
        let reasonClass = reasonOverride ?? state.reasonClass
        let windowStart: String
        if let previous = state.windowStartedAt,
           let now = date(timestamp), let started = date(previous),
           now.timeIntervalSince(started) < TimeInterval(state.windowSeconds) {
            windowStart = previous
        } else {
            windowStart = timestamp
        }
        var exponential = min(state.initialBackoffSeconds, state.maximumBackoffSeconds)
        for _ in 1..<attempt {
            guard exponential < state.maximumBackoffSeconds else { break }
            if exponential > state.maximumBackoffSeconds / 2 {
                exponential = state.maximumBackoffSeconds
            } else {
                exponential = min(state.maximumBackoffSeconds, exponential * 2)
            }
        }
        let jitter = deterministicJitter(
            projectID: state.projectID,
            serviceName: state.serviceName,
            attempt: attempt,
            policySHA256: state.policySHA256,
            maximum: state.jitterSeconds
        )
        let delay = exponential + min(
            jitter,
            state.maximumBackoffSeconds - exponential
        )
        let until = date(timestamp).map {
            ISO8601DateFormatter().string(from: $0.addingTimeInterval(TimeInterval(delay)))
        }
        let updated = RestartPolicyStateRecord(
            id: state.id,
            projectID: state.projectID,
            serviceName: state.serviceName,
            policy: state.policy,
            status: .backingOff,
            attemptCount: attempt,
            maxAttempts: state.maxAttempts,
            backoffSeconds: delay,
            backoffUntil: until,
            lastFailureAt: timestamp,
            reasonClass: reasonClass,
            windowStartedAt: windowStart,
            windowSeconds: state.windowSeconds,
            initialBackoffSeconds: state.initialBackoffSeconds,
            maximumBackoffSeconds: state.maximumBackoffSeconds,
            jitterSeconds: state.jitterSeconds,
            stableRunSeconds: state.stableRunSeconds,
            stableSince: nil,
            priority: state.priority,
            projectMaxAttempts: state.projectMaxAttempts,
            projectWindowSeconds: state.projectWindowSeconds,
            holdToken: nil,
            releaseGeneration: state.releaseGeneration,
            policySHA256: state.policySHA256,
            updatedAt: timestamp,
            metadataJSONRedacted: metadata(
                attemptCount: attempt,
                reason: reasonClass,
                status: .backingOff
            )
        )
        let history = RestartAttemptHistoryRecord(
            id: historyID,
            projectID: state.projectID,
            serviceName: state.serviceName,
            reasonClass: reasonClass,
            decision: failed ? .failed : .admitted,
            attemptNumber: attempt,
            projectAttemptNumber: projectAttemptNumber,
            admitted: true,
            releaseGeneration: state.releaseGeneration,
            operationID: operationID,
            occurredAt: timestamp,
            backoffUntil: until,
            policySHA256: state.policySHA256,
            metadataJSONRedacted: metadata(
                attemptCount: attempt,
                reason: reasonClass,
                status: .backingOff
            )
        )
        return RestartBudgetAttemptResult(state: updated, history: history)
    }

    public static func decision(
        desired: DesiredRuntimeService,
        state: RestartPolicyStateRecord?,
        currentTimestamp: String?
    ) -> RestartPolicyDecision {
        guard desired.restartPolicy.allowsManagedStart else {
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is not running; restart policy does not allow managed start.",
                isBlocked: false
            )
        }

        guard let state else {
            return RestartPolicyDecision(
                executionAvailability: .availableForStartManagedService,
                reason: "Observed service is not running; restart policy allows one confirmed managed start.",
                isBlocked: false
            )
        }

        if state.attemptCount >= state.maxAttempts {
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is not running; crash-loop protection blocks managed start after \(state.attemptCount)/\(state.maxAttempts) attempts. Operator action is required before another start.",
                isBlocked: true
            )
        }

        switch state.status {
        case .active, .stablePending:
            return RestartPolicyDecision(
                executionAvailability: .availableForStartManagedService,
                reason: "Observed service is not running; restart policy allows one confirmed managed start with \(state.attemptCount)/\(state.maxAttempts) attempts used.",
                isBlocked: false
            )
        case .backingOff:
            if backoffElapsed(state.backoffUntil, at: currentTimestamp) {
                return RestartPolicyDecision(
                    executionAvailability: .availableForStartManagedService,
                    reason: "Observed service is not running; restart backoff elapsed at \(state.backoffUntil ?? "unknown"), so one confirmed managed start is available.",
                    isBlocked: false
                )
            }
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is not running; restart backoff is active until \(state.backoffUntil ?? "operator reset") after \(state.attemptCount)/\(state.maxAttempts) attempts.",
                isBlocked: true
            )
        case .operatorHold:
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is not running; operator hold blocks managed start until the hold is cleared.",
                isBlocked: true
            )
        case .manualDisabled:
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is not running; restart policy is manually disabled for this service.",
                isBlocked: true
            )
        case .crashLoopBlocked:
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is not running; crash-loop protection blocks managed start after \(state.attemptCount)/\(state.maxAttempts) attempts. Operator action is required before another start.",
                isBlocked: true
            )
        case .projectBudgetBlocked:
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is not running; the project restart budget blocks another managed start in the current rolling window.",
                isBlocked: true
            )
        }
    }

    public static func restartDecision(
        desired: DesiredRuntimeService,
        state: RestartPolicyStateRecord?,
        currentTimestamp: String?
    ) -> RestartPolicyDecision {
        guard desired.restartPolicy.allowsManagedStart else {
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is unhealthy but running; restart policy does not allow managed restart.",
                isBlocked: false
            )
        }

        guard let state else {
            return RestartPolicyDecision(
                executionAvailability: .availableForRestartManagedService,
                reason: "Observed service is unhealthy and running; restart policy allows one confirmed managed restart.",
                isBlocked: false
            )
        }

        if state.attemptCount >= state.maxAttempts {
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is unhealthy and running; crash-loop protection blocks managed restart after \(state.attemptCount)/\(state.maxAttempts) attempts. Operator action is required before another restart.",
                isBlocked: true
            )
        }

        switch state.status {
        case .active, .stablePending:
            return RestartPolicyDecision(
                executionAvailability: .availableForRestartManagedService,
                reason: "Observed service is unhealthy and running; restart policy allows one confirmed managed restart with \(state.attemptCount)/\(state.maxAttempts) attempts used.",
                isBlocked: false
            )
        case .backingOff:
            if backoffElapsed(state.backoffUntil, at: currentTimestamp) {
                return RestartPolicyDecision(
                    executionAvailability: .availableForRestartManagedService,
                    reason: "Observed service is unhealthy and running; restart backoff elapsed at \(state.backoffUntil ?? "unknown"), so one confirmed managed restart is available.",
                    isBlocked: false
                )
            }
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is unhealthy and running; restart backoff is active until \(state.backoffUntil ?? "operator reset") after \(state.attemptCount)/\(state.maxAttempts) attempts.",
                isBlocked: true
            )
        case .operatorHold:
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is unhealthy and running; operator hold blocks managed restart until the hold is cleared.",
                isBlocked: true
            )
        case .manualDisabled:
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is unhealthy and running; restart policy is manually disabled for this service.",
                isBlocked: true
            )
        case .crashLoopBlocked:
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is unhealthy and running; crash-loop protection blocks managed restart after \(state.attemptCount)/\(state.maxAttempts) attempts. Operator action is required before another restart.",
                isBlocked: true
            )
        case .projectBudgetBlocked:
            return RestartPolicyDecision(
                executionAvailability: .unavailable,
                reason: "Observed service is unhealthy and running; the project restart budget blocks another managed restart in the current rolling window.",
                isBlocked: true
            )
        }
    }

    private static func classify(
        lifecycle: RuntimeLifecycleState?,
        health: RuntimeHealthState?
    ) -> RestartReasonClass {
        if health == .unhealthy { return .healthFailure }
        if lifecycle == .failed { return .runtimeFailure }
        if lifecycle == nil || lifecycle == .stopped || lifecycle == .exited {
            return .processExit
        }
        return .unknown
    }

    private static func backoffElapsed(_ backoffUntil: String?, at timestamp: String?) -> Bool {
        guard let backoffUntil, let timestamp,
              let deadline = date(backoffUntil), let now = date(timestamp) else {
            return false
        }
        return now >= deadline
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func deterministicJitter(
        projectID: String,
        serviceName: String,
        attempt: Int,
        policySHA256: String,
        maximum: Int
    ) -> Int {
        guard maximum > 0 else { return 0 }
        let input = "\(projectID)|\(serviceName)|\(attempt)|\(policySHA256)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(value % UInt64(maximum + 1))
    }

    private static func makeHoldToken(
        projectID: String,
        serviceName: String,
        attemptCount: Int,
        windowStartedAt: String?,
        releaseGeneration: Int,
        policySHA256: String
    ) -> String {
        let input = "\(projectID)|\(serviceName)|\(attemptCount)|\(windowStartedAt ?? "")|\(releaseGeneration)|\(policySHA256)"
        return SHA256.hash(data: Data(input.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func selfReset(
        _ backoffUntil: inout String?,
        _ lastFailureAt: inout String?,
        _ holdToken: inout String?
    ) {
        backoffUntil = nil
        lastFailureAt = nil
        holdToken = nil
    }

    private static func metadata(
        attemptCount: Int,
        reason: RestartReasonClass,
        status: RestartPolicyStateStatus
    ) -> String {
        "{\"attemptCount\":\(attemptCount),\"reasonClass\":\"\(reason.rawValue)\",\"status\":\"\(status.rawValue)\"}"
    }
}
