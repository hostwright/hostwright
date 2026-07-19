import Foundation

public enum RuntimeFailureCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case unavailable
    case incompatible
    case rejected
    case permissionDenied = "permission-denied"
    case invalidResponse = "invalid-response"
    case timedOut = "timed-out"
    case cancelled
    case outputLimited = "output-limited"
    case crashed
    case partialEffect = "partial-effect"
    case ambiguousEffect = "ambiguous-effect"
    case staleCapability = "stale-capability"
    case fencingConflict = "fencing-conflict"
}

public enum RuntimeRetryDisposition: String, Codable, Equatable, Sendable {
    case never
    case safeAfterObservation = "safe-after-observation"
    case resumeFromCheckpoint = "resume-from-checkpoint"
}

public enum RuntimeRecoveryDisposition: String, Codable, Equatable, Sendable {
    case none
    case reobserve
    case resume
    case compensate
}

public struct RuntimeNormalizedFailure: Codable, Equatable, Sendable {
    public static let maximumDiagnosticBytes = 4_096
    public static let maximumGuidanceBytes = 1_024

    public let category: RuntimeFailureCategory
    public let retryDisposition: RuntimeRetryDisposition
    public let recoveryDisposition: RuntimeRecoveryDisposition
    public let providerID: String
    public let providerVersion: String
    public let operationID: String
    public let diagnostic: String
    public let guidance: String

    public init(
        category: RuntimeFailureCategory,
        retryDisposition: RuntimeRetryDisposition,
        recoveryDisposition: RuntimeRecoveryDisposition,
        providerID: String,
        providerVersion: String,
        operationID: String,
        diagnostic: String,
        guidance: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.category = category
        self.retryDisposition = retryDisposition
        self.recoveryDisposition = recoveryDisposition
        self.providerID = Self.bounded(redactionPolicy.redact(providerID), maximumBytes: 256)
        self.providerVersion = Self.bounded(redactionPolicy.redact(providerVersion), maximumBytes: 256)
        self.operationID = Self.bounded(redactionPolicy.redact(operationID), maximumBytes: 256)
        self.diagnostic = Self.bounded(
            redactionPolicy.redact(diagnostic),
            maximumBytes: Self.maximumDiagnosticBytes
        )
        self.guidance = Self.bounded(
            redactionPolicy.redact(guidance),
            maximumBytes: Self.maximumGuidanceBytes
        )
    }

    public var requiresObservationBeforeRetry: Bool {
        retryDisposition == .safeAfterObservation ||
            category == .partialEffect ||
            category == .ambiguousEffect ||
            category == .timedOut ||
            category == .cancelled ||
            category == .crashed
    }

    public func redacted(
        using policy: RuntimeRedactionPolicy = .default,
        exactValues: [String] = []
    ) -> RuntimeNormalizedFailure {
        RuntimeNormalizedFailure(
            category: category,
            retryDisposition: retryDisposition,
            recoveryDisposition: recoveryDisposition,
            providerID: policy.redact(providerID, exactValues: exactValues),
            providerVersion: policy.redact(providerVersion, exactValues: exactValues),
            operationID: policy.redact(operationID, exactValues: exactValues),
            diagnostic: policy.redact(diagnostic, exactValues: exactValues),
            guidance: policy.redact(guidance, exactValues: exactValues),
            redactionPolicy: policy
        )
    }

    public static func normalize(
        _ error: RuntimeAdapterError,
        providerID: String,
        providerVersion: String,
        operationID: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) -> RuntimeNormalizedFailure {
        let redacted = error.redacted(using: redactionPolicy)
        if case .normalizedFailure(let failure) = redacted {
            return failure
        }
        let classification = classification(for: redacted)
        return RuntimeNormalizedFailure(
            category: classification.category,
            retryDisposition: classification.retry,
            recoveryDisposition: classification.recovery,
            providerID: providerID,
            providerVersion: providerVersion,
            operationID: operationID,
            diagnostic: "Provider failure normalized as \(classification.category.rawValue).",
            guidance: guidance(for: classification.category),
            redactionPolicy: redactionPolicy
        )
    }

    private static func classification(
        for error: RuntimeAdapterError
    ) -> (category: RuntimeFailureCategory, retry: RuntimeRetryDisposition, recovery: RuntimeRecoveryDisposition) {
        switch error {
        case .runtimeUnavailable, .executableNotFound:
            return (.unavailable, .safeAfterObservation, .reobserve)
        case .unsupportedRuntime:
            return (.incompatible, .never, .none)
        case .commandRejected, .commandFailed, .capabilityUnavailable, .mutationUnavailableByPolicy:
            return (.rejected, .never, .none)
        case .permissionDenied:
            return (.permissionDenied, .never, .none)
        case .outputParseFailed, .redactionFailure:
            return (.invalidResponse, .safeAfterObservation, .reobserve)
        case .commandTimedOut:
            return (.timedOut, .safeAfterObservation, .reobserve)
        case .commandCancelled:
            return (.cancelled, .safeAfterObservation, .reobserve)
        case .commandOutputLimitExceeded:
            return (.outputLimited, .safeAfterObservation, .reobserve)
        case .commandProcessTreeViolation:
            return (.crashed, .safeAfterObservation, .reobserve)
        case .managedRestartStartFailedAfterStop:
            return (.partialEffect, .resumeFromCheckpoint, .resume)
        case .normalizedFailure(let failure):
            return (
                failure.category,
                failure.retryDisposition,
                failure.recoveryDisposition
            )
        }
    }

    private static func guidance(for category: RuntimeFailureCategory) -> String {
        switch category {
        case .unavailable:
            return "Restore the selected runtime provider, then re-observe before retrying."
        case .incompatible:
            return "Install a supported provider version and negotiate capabilities again."
        case .rejected:
            return "Correct the rejected request before attempting it again."
        case .permissionDenied:
            return "Restore the required local permission without weakening the trust boundary."
        case .invalidResponse:
            return "Treat provider state as unknown and re-observe with a supported codec."
        case .timedOut, .cancelled, .outputLimited, .crashed, .ambiguousEffect:
            return "Re-observe the exact owned resource before deciding whether to retry."
        case .partialEffect:
            return "Resume from the recorded checkpoint or run its verified compensation."
        case .staleCapability:
            return "Negotiate a fresh capability snapshot and generate a new plan."
        case .fencingConflict:
            return "Stop and inspect the active operation and current fencing token."
        }
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        let bytes = Array(value.utf8.prefix(maximumBytes))
        return String(decoding: bytes, as: UTF8.self)
    }
}
