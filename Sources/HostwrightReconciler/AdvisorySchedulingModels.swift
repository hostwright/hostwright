import HostwrightHealth
import HostwrightPolicy
import HostwrightRuntime

public enum AdvisoryWorkloadClass: String, Equatable, Hashable, Sendable {
    case interactiveService
    case backgroundWorker
    case batchJob
    case localAI
    case unknown

    var sortIndex: Int {
        switch self {
        case .interactiveService: 0
        case .backgroundWorker: 1
        case .batchJob: 2
        case .localAI: 3
        case .unknown: 4
        }
    }
}

public struct AdvisoryResourceRequest: Equatable, Sendable {
    public let memoryBytes: Int?
    public let workloadClass: AdvisoryWorkloadClass
    public let acceleratorRequirements: [String]
    public let requiresRemotePlacement: Bool

    public init(
        memoryBytes: Int? = nil,
        workloadClass: AdvisoryWorkloadClass = .unknown,
        acceleratorRequirements: [String] = [],
        requiresRemotePlacement: Bool = false
    ) {
        self.memoryBytes = memoryBytes
        self.workloadClass = workloadClass
        self.acceleratorRequirements = acceleratorRequirements
        self.requiresRemotePlacement = requiresRemotePlacement
    }
}

public struct AdvisorySchedulingConfiguration: Equatable, Sendable {
    public let localHostIdentifier: String
    public let advisoryMemoryBudgetPercent: Int
    public let fairnessWarningThresholdPerClass: Int
    public let localPolicyEvaluator: LocalPolicyEvaluator

    public init(
        localHostIdentifier: String = "local",
        advisoryMemoryBudgetPercent: Int = 70,
        fairnessWarningThresholdPerClass: Int = 2,
        localPolicyEvaluator: LocalPolicyEvaluator = .default
    ) {
        self.localHostIdentifier = localHostIdentifier
        self.advisoryMemoryBudgetPercent = min(max(advisoryMemoryBudgetPercent, 1), 100)
        self.fairnessWarningThresholdPerClass = max(1, fairnessWarningThresholdPerClass)
        self.localPolicyEvaluator = localPolicyEvaluator
    }

    public static let `default` = AdvisorySchedulingConfiguration()
}

public struct AdvisorySchedulingInput: Equatable, Sendable {
    public let desiredState: DesiredRuntimeState
    public let observedState: ObservedRuntimeState?
    public let resourceReport: ResourceIntelligenceReport
    public let resourceRequests: [RuntimeServiceIdentity: AdvisoryResourceRequest]
    public let configuration: AdvisorySchedulingConfiguration

    public init(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState?,
        resourceReport: ResourceIntelligenceReport,
        resourceRequests: [RuntimeServiceIdentity: AdvisoryResourceRequest] = [:],
        configuration: AdvisorySchedulingConfiguration = .default
    ) {
        self.desiredState = desiredState
        self.observedState = observedState
        self.resourceReport = resourceReport
        self.resourceRequests = resourceRequests
        self.configuration = configuration
    }
}

public enum AdvisorySchedulingRecommendationStatus: String, Equatable, Sendable {
    case recommended
    case blocked

    var sortIndex: Int {
        switch self {
        case .recommended: 0
        case .blocked: 1
        }
    }
}

public enum AdvisorySchedulingReasonCategory: String, Equatable, Sendable {
    case policy
    case memory
    case thermal
    case fairness
    case workloadClass
    case accelerator
    case placement
}

public enum AdvisorySchedulingReasonCode: String, Equatable, Sendable {
    case localHostCandidate
    case policyBlocker
    case policyWarning
    case memoryRequestMissing
    case memoryRequestInvalid
    case memoryBudgetUnavailable
    case memoryWithinAdvisoryBudget
    case memoryRequestExceedsHostMemory
    case memoryOvercommit
    case thermalPressureWarning
    case workloadClassConsidered
    case workloadClassFairnessPenalty
    case acceleratorUnsupported
    case remotePlacementUnsupported
}

public struct AdvisorySchedulingReason: Equatable, Sendable {
    public let category: AdvisorySchedulingReasonCategory
    public let reasonCode: AdvisorySchedulingReasonCode
    public let severity: PolicyDecisionSeverity
    public let message: String
    public let remediation: String
    public let stableDetailKey: String
    public let scoreImpact: Int
    public let policyReasonCode: PolicyReasonCode?

    public init(
        category: AdvisorySchedulingReasonCategory,
        reasonCode: AdvisorySchedulingReasonCode,
        severity: PolicyDecisionSeverity,
        message: String,
        remediation: String,
        stableDetailKey: String,
        scoreImpact: Int = 0,
        policyReasonCode: PolicyReasonCode? = nil
    ) {
        self.category = category
        self.reasonCode = reasonCode
        self.severity = severity
        self.message = message
        self.remediation = remediation
        self.stableDetailKey = stableDetailKey
        self.scoreImpact = scoreImpact
        self.policyReasonCode = policyReasonCode
    }

    public var orderingKey: String {
        [
            String(format: "%03d", severitySortIndex(severity)),
            category.rawValue,
            reasonCode.rawValue,
            policyReasonCode?.rawValue ?? "",
            stableDetailKey,
            message
        ].joined(separator: "|")
    }
}

public struct AdvisorySchedulingRecommendation: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let hostIdentifier: String
    public let workloadClass: AdvisoryWorkloadClass
    public let requestedMemoryBytes: Int?
    public let status: AdvisorySchedulingRecommendationStatus
    public let score: Int
    public let reasons: [AdvisorySchedulingReason]

    public init(
        identity: RuntimeServiceIdentity,
        hostIdentifier: String,
        workloadClass: AdvisoryWorkloadClass,
        requestedMemoryBytes: Int?,
        status: AdvisorySchedulingRecommendationStatus,
        score: Int,
        reasons: [AdvisorySchedulingReason]
    ) {
        self.identity = identity
        self.hostIdentifier = hostIdentifier
        self.workloadClass = workloadClass
        self.requestedMemoryBytes = requestedMemoryBytes
        self.status = status
        self.score = score
        self.reasons = reasons.sorted { $0.orderingKey < $1.orderingKey }
    }

    public var orderingKey: String {
        [
            String(format: "%03d", status.sortIndex),
            String(format: "%03d", 100 - score),
            identity.projectName,
            identity.serviceName,
            identity.instanceName ?? ""
        ].joined(separator: "|")
    }
}

public struct AdvisorySchedulingReport: Equatable, Sendable {
    public let advisoryOnly: Bool
    public let hostIdentifier: String
    public let advisoryMemoryBudgetBytes: Int?
    public let totalDeclaredMemoryBytes: Int
    public let recommendations: [AdvisorySchedulingRecommendation]

    public init(
        advisoryOnly: Bool = true,
        hostIdentifier: String,
        advisoryMemoryBudgetBytes: Int?,
        totalDeclaredMemoryBytes: Int,
        recommendations: [AdvisorySchedulingRecommendation]
    ) {
        self.advisoryOnly = advisoryOnly
        self.hostIdentifier = hostIdentifier
        self.advisoryMemoryBudgetBytes = advisoryMemoryBudgetBytes
        self.totalDeclaredMemoryBytes = totalDeclaredMemoryBytes
        self.recommendations = recommendations.sorted { $0.orderingKey < $1.orderingKey }
    }

    public var hasBlockers: Bool {
        recommendations.contains { $0.status == .blocked }
    }
}

func severitySortIndex(_ severity: PolicyDecisionSeverity) -> Int {
    switch severity {
    case .blocker:
        return 0
    case .warning:
        return 1
    case .allow:
        return 2
    }
}
