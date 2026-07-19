import Foundation
import HostwrightRuntime
import HostwrightState

public enum DriftSeverity: String, Comparable, Equatable, Sendable {
    case blocker
    case error
    case warning
    case info

    private var sortIndex: Int {
        switch self {
        case .blocker: 0
        case .error: 1
        case .warning: 2
        case .info: 3
        }
    }

    public static func < (lhs: DriftSeverity, rhs: DriftSeverity) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }
}

public enum DriftKind: String, Equatable, Sendable {
    case missingDesiredService
    case stoppedService
    case failedService
    case unhealthyService
    case unmanagedObservedService
    case imageMismatch
    case portMismatch
    case mountMismatch
    case duplicateObservedIdentity
    case unsupportedObservedState
    case observationUnavailable

    public var sortIndex: Int {
        switch self {
        case .observationUnavailable: 0
        case .duplicateObservedIdentity: 1
        case .unsupportedObservedState: 2
        case .unmanagedObservedService: 3
        case .missingDesiredService: 4
        case .stoppedService: 5
        case .failedService: 6
        case .imageMismatch: 7
        case .portMismatch: 8
        case .mountMismatch: 9
        case .unhealthyService: 10
        }
    }
}

public struct DriftRecord: Equatable, Sendable {
    public let kind: DriftKind
    public let severity: DriftSeverity
    public let identity: RuntimeServiceIdentity?
    public let reason: String
    public let stableDetailKey: String

    public init(
        kind: DriftKind,
        severity: DriftSeverity,
        identity: RuntimeServiceIdentity?,
        reason: String,
        stableDetailKey: String = ""
    ) {
        self.kind = kind
        self.severity = severity
        self.identity = identity
        self.reason = reason
        self.stableDetailKey = stableDetailKey
    }

    public var orderingKey: String {
        [
            identity?.projectName ?? "",
            identity?.serviceName ?? "",
            String(format: "%03d", kind.sortIndex),
            stableDetailKey
        ].joined(separator: "|")
    }
}

public enum PlanActionKind: String, Equatable, Sendable {
    case createMissingService
    case flagUnmanagedService
    case proposeStartStoppedService
    case investigateFailedService
    case replaceForImageDrift
    case reconcilePortDrift
    case reconcileMountDrift
    case investigateUnhealthyService
    case restartManagedService

    public var sortIndex: Int {
        switch self {
        case .flagUnmanagedService: 3
        case .createMissingService: 4
        case .proposeStartStoppedService: 5
        case .investigateFailedService: 6
        case .replaceForImageDrift: 7
        case .reconcilePortDrift: 8
        case .reconcileMountDrift: 9
        case .restartManagedService: 10
        case .investigateUnhealthyService: 11
        }
    }
}

public enum PlanExecutionAvailability: String, Equatable, Sendable {
    case unavailable
    case availableForCreateMissingService
    case availableForStartManagedService
    case availableForRestartManagedService
}

public struct PlannedAction: Equatable, Sendable {
    public let kind: PlanActionKind
    public let identity: RuntimeServiceIdentity
    public let resourceIdentifier: String
    public let reason: String
    public let driftKind: DriftKind
    public let stableDetailKey: String
    public let executionAvailability: PlanExecutionAvailability

    public init(
        kind: PlanActionKind,
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String,
        reason: String,
        driftKind: DriftKind,
        stableDetailKey: String = "",
        executionAvailability: PlanExecutionAvailability = .unavailable
    ) {
        self.kind = kind
        self.identity = identity
        self.resourceIdentifier = resourceIdentifier
        self.reason = reason
        self.driftKind = driftKind
        self.stableDetailKey = stableDetailKey
        self.executionAvailability = executionAvailability
    }

    public var orderingKey: String {
        [
            identity.projectName,
            identity.serviceName,
            resourceIdentifier,
            String(format: "%03d", kind.sortIndex),
            stableDetailKey
        ].joined(separator: "|")
    }
}

public enum PlanIssueKind: String, Equatable, Sendable {
    case duplicateDesiredHostPort
    case hostPortConflict
    case unsafeExposure
    case privilegedHostPort
    case ambiguousVolumeReference
    case unsafeVolumePath
    case unsupportedFeature
    case secretRedacted
    case invalidDesiredIdentity
    case duplicateObservedIdentity
    case unsupportedObservedState
    case observationUnavailable
    case restartPolicyBlocked

    public var sortIndex: Int {
        switch self {
        case .duplicateDesiredHostPort: 0
        case .hostPortConflict: 1
        case .unsafeExposure: 2
        case .privilegedHostPort: 3
        case .ambiguousVolumeReference: 4
        case .unsafeVolumePath: 5
        case .unsupportedFeature: 6
        case .secretRedacted: 7
        case .invalidDesiredIdentity: 8
        case .duplicateObservedIdentity: 9
        case .unsupportedObservedState: 10
        case .observationUnavailable: 11
        case .restartPolicyBlocked: 12
        }
    }
}

public struct PlanIssue: Equatable, Sendable {
    public let kind: PlanIssueKind
    public let severity: DriftSeverity
    public let identity: RuntimeServiceIdentity?
    public let message: String
    public let stableDetailKey: String

    public init(
        kind: PlanIssueKind,
        severity: DriftSeverity,
        identity: RuntimeServiceIdentity?,
        message: String,
        stableDetailKey: String = ""
    ) {
        self.kind = kind
        self.severity = severity
        self.identity = identity
        self.message = message
        self.stableDetailKey = stableDetailKey
    }

    public var orderingKey: String {
        [
            identity?.projectName ?? "",
            identity?.serviceName ?? "",
            String(format: "%03d", kind.sortIndex),
            stableDetailKey
        ].joined(separator: "|")
    }
}

public struct PlanningInput: Equatable, Sendable {
    public let desiredState: DesiredRuntimeState
    public let observedState: ObservedRuntimeState?
    public let policy: PlanningPolicy
    public let additionalIssues: [PlanIssue]
    public let restartPolicyStates: [RuntimeServiceIdentity: RestartPolicyStateRecord]
    public let currentTimestamp: String?

    public init(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState?,
        policy: PlanningPolicy = .default,
        additionalIssues: [PlanIssue] = [],
        restartPolicyStates: [RuntimeServiceIdentity: RestartPolicyStateRecord] = [:],
        currentTimestamp: String? = nil
    ) {
        self.desiredState = desiredState
        self.observedState = observedState
        self.policy = policy
        self.additionalIssues = additionalIssues
        self.restartPolicyStates = restartPolicyStates
        self.currentTimestamp = currentTimestamp
    }
}

public struct ReconciliationPlan: Equatable, Sendable {
    public let projectName: String
    public let observationConnected: Bool
    public let capabilitySHA256: String?
    public let issues: [PlanIssue]
    public let drift: [DriftRecord]
    public let actions: [PlannedAction]
    public let planHash: String

    public init(
        projectName: String,
        observationConnected: Bool,
        capabilitySHA256: String? = nil,
        issues: [PlanIssue],
        drift: [DriftRecord],
        actions: [PlannedAction]
    ) {
        self.projectName = projectName
        self.observationConnected = observationConnected
        self.capabilitySHA256 = capabilitySHA256
        self.issues = issues.sorted { $0.orderingKey < $1.orderingKey }
        self.drift = drift.sorted { $0.orderingKey < $1.orderingKey }
        self.actions = actions.sorted { $0.orderingKey < $1.orderingKey }
        self.planHash = PlanHasher.hash(
            projectName: projectName,
            observationConnected: observationConnected,
            capabilitySHA256: capabilitySHA256,
            issues: self.issues,
            drift: self.drift,
            actions: self.actions
        )
    }

    public var mutatesRuntime: Bool {
        false
    }

    public var includesBlockers: Bool {
        issues.contains { $0.severity == .blocker }
    }
}

enum PlanHasher {
    static func hash(
        projectName: String,
        observationConnected: Bool,
        capabilitySHA256: String?,
        issues: [PlanIssue],
        drift: [DriftRecord],
        actions: [PlannedAction]
    ) -> String {
        var parts: [String] = [
            "project=\(projectName)",
            "observed=\(observationConnected)",
            "capability=\(capabilitySHA256 ?? "unbound")"
        ]

        parts += issues.map { issue in
            "issue|\(issue.kind.rawValue)|\(issue.severity.rawValue)|\(issue.identity?.displayName ?? "")|\(issue.message)|\(issue.stableDetailKey)"
        }
        parts += drift.map { record in
            "drift|\(record.kind.rawValue)|\(record.severity.rawValue)|\(record.identity?.displayName ?? "")|\(record.reason)|\(record.stableDetailKey)"
        }
        parts += actions.map { action in
            "action|\(action.kind.rawValue)|\(action.identity.displayName)|\(action.resourceIdentifier)|\(action.reason)|\(action.driftKind.rawValue)|\(action.stableDetailKey)|\(action.executionAvailability.rawValue)"
        }

        return fnv1a64(parts.joined(separator: "\n"))
    }

    private static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
