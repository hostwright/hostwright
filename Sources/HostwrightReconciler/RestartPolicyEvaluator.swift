import HostwrightRuntime
import HostwrightState

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
        case .active:
            return RestartPolicyDecision(
                executionAvailability: .availableForStartManagedService,
                reason: "Observed service is not running; restart policy allows one confirmed managed start with \(state.attemptCount)/\(state.maxAttempts) attempts used.",
                isBlocked: false
            )
        case .backingOff:
            if let backoffUntil = state.backoffUntil,
               let currentTimestamp,
               currentTimestamp >= backoffUntil {
                return RestartPolicyDecision(
                    executionAvailability: .availableForStartManagedService,
                    reason: "Observed service is not running; restart backoff elapsed at \(backoffUntil), so one confirmed managed start is available.",
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
        case .active:
            return RestartPolicyDecision(
                executionAvailability: .availableForRestartManagedService,
                reason: "Observed service is unhealthy and running; restart policy allows one confirmed managed restart with \(state.attemptCount)/\(state.maxAttempts) attempts used.",
                isBlocked: false
            )
        case .backingOff:
            if let backoffUntil = state.backoffUntil,
               let currentTimestamp,
               currentTimestamp >= backoffUntil {
                return RestartPolicyDecision(
                    executionAvailability: .availableForRestartManagedService,
                    reason: "Observed service is unhealthy and running; restart backoff elapsed at \(backoffUntil), so one confirmed managed restart is available.",
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
        }
    }
}
