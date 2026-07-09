import Foundation

public enum TeamWorkflowGate: String, CaseIterable, Equatable, Sendable {
    case runtimeAdapter
    case explicitStatePath
    case localPolicy
    case redaction
    case auditTrail
    case planConfirmation
    case cleanupConfirmation
    case ownershipChecks
    case localOnlyNoCloud
    case noTelemetryUpload
}

public enum TeamPolicyOverrideKind: String, Equatable, Sendable {
    case requireImageDigest
    case requireManifestReview
    case allowPrivilegedPortWarning
    case allowBroadBindAddress
    case bypassPlanConfirmation
    case bypassCleanupConfirmation
    case bypassOwnershipChecks
    case defaultStatePath
    case telemetryUpload
    case runtimeMutationExpansion
}

public enum TeamPolicyOverrideEffect: String, Equatable, Sendable {
    case stricter
    case documentedException
    case weakensRequiredGate
}

public struct TeamPolicyOverride: Equatable, Sendable {
    public let kind: TeamPolicyOverrideKind
    public let effect: TeamPolicyOverrideEffect
    public let justification: String
    public let approvalID: String?

    public init(
        kind: TeamPolicyOverrideKind,
        effect: TeamPolicyOverrideEffect,
        justification: String,
        approvalID: String? = nil
    ) {
        self.kind = kind
        self.effect = effect
        self.justification = justification
        self.approvalID = approvalID
    }
}

public enum TeamApprovalDecision: String, Equatable, Sendable {
    case approved
    case rejected
}

public struct TeamApprovalRecord: Equatable, Sendable {
    public let id: String
    public let reviewer: String
    public let decision: TeamApprovalDecision
    public let scope: String
    public let recordedAt: String

    public init(
        id: String,
        reviewer: String,
        decision: TeamApprovalDecision,
        scope: String,
        recordedAt: String
    ) {
        self.id = id
        self.reviewer = reviewer
        self.decision = decision
        self.scope = scope
        self.recordedAt = recordedAt
    }
}

public struct TeamPolicyProfile: Equatable, Sendable {
    public let identifier: String
    public let version: Int
    public let displayName: String
    public let optIn: Bool
    public let requiredGates: [TeamWorkflowGate]
    public let overrides: [TeamPolicyOverride]
    public let approvals: [TeamApprovalRecord]

    public init(
        identifier: String,
        version: Int = 1,
        displayName: String,
        optIn: Bool,
        requiredGates: [TeamWorkflowGate],
        overrides: [TeamPolicyOverride] = [],
        approvals: [TeamApprovalRecord] = []
    ) {
        self.identifier = identifier
        self.version = version
        self.displayName = displayName
        self.optIn = optIn
        self.requiredGates = requiredGates
        self.overrides = overrides
        self.approvals = approvals
    }
}

public struct TeamWorkflowPolicyEvaluator: Equatable, Sendable {
    public init() {}

    public static let `default` = TeamWorkflowPolicyEvaluator()

    public func evaluate(_ profile: TeamPolicyProfile) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []
        let identifier = profile.identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        if identifier.isEmpty {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileMissingIdentity,
                    severity: .blocker,
                    subject: "identity",
                    message: "Team policy profiles must include a stable identifier.",
                    remediation: "Declare a stable local team profile identifier before applying team defaults."
                )
            )
        }

        if profile.version != 1 {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileUnsupportedVersion,
                    severity: .blocker,
                    subject: "version",
                    message: "Team policy profile version \(profile.version) is not supported.",
                    remediation: "Use team policy profile version 1 until a later compatibility policy is approved."
                )
            )
        }

        if !profile.optIn {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileNotOptIn,
                    severity: .blocker,
                    subject: "optIn",
                    message: "Team policy profiles must be explicitly opted in.",
                    remediation: "Set opt-in explicitly in the local workflow; Hostwright does not apply team defaults silently."
                )
            )
        }

        for gate in TeamWorkflowGate.allCases where !profile.requiredGates.contains(gate) {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileMissingRequiredGate,
                    severity: .blocker,
                    subject: gate.rawValue,
                    message: "Team policy profile is missing required gate '\(gate.rawValue)'.",
                    remediation: "Keep required Hostwright gates declared; team defaults cannot remove runtime, state, redaction, audit, confirmation, ownership, or local-only boundaries."
                )
            )
        }

        for override in profile.overrides {
            decisions.append(contentsOf: evaluateOverride(override, profile: profile))
        }

        if decisions.isEmpty {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileDeclared,
                    severity: .allow,
                    subject: identifier,
                    message: "Team policy profile '\(identifier)' is local, opt-in, auditable, and preserves required Hostwright gates.",
                    remediation: "Record approvals and audit events before using the profile in team review workflows."
                )
            )
        }

        return decisions.sorted { $0.orderingKey < $1.orderingKey }
    }

    private func evaluateOverride(_ override: TeamPolicyOverride, profile: TeamPolicyProfile) -> [PolicyDecision] {
        if forbiddenOverrideKinds.contains(override.kind) {
            return [
                decision(
                    profile: profile,
                    reasonCode: .teamOverrideForbidden,
                    severity: .blocker,
                    subject: override.kind.rawValue,
                    message: "Team policy override '\(override.kind.rawValue)' cannot bypass required Hostwright safety gates.",
                    remediation: "Remove the override; hard-coded runtime, state, redaction, confirmation, ownership, local-only, and telemetry boundaries remain mandatory."
                )
            ]
        }

        if override.effect == .weakensRequiredGate && !hasApprovedRecord(id: override.approvalID, in: profile.approvals) {
            return [
                decision(
                    profile: profile,
                    reasonCode: .teamOverrideRequiresApproval,
                    severity: .blocker,
                    subject: override.kind.rawValue,
                    message: "Team policy override '\(override.kind.rawValue)' requires an approved local review record.",
                    remediation: "Record a local approval for the exact override or remove it from the profile."
                )
            ]
        }

        if let approvalID = override.approvalID, hasApprovedRecord(id: approvalID, in: profile.approvals) {
            return [
                decision(
                    profile: profile,
                    reasonCode: .teamApprovalRecorded,
                    severity: .warning,
                    subject: override.kind.rawValue,
                    message: "Team policy override '\(override.kind.rawValue)' has an approved local review record.",
                    remediation: "Approved profile records document review only; they do not bypass hard-coded Hostwright safety gates."
                )
            ]
        }

        return []
    }

    private var forbiddenOverrideKinds: [TeamPolicyOverrideKind] {
        [
            .allowBroadBindAddress,
            .bypassPlanConfirmation,
            .bypassCleanupConfirmation,
            .bypassOwnershipChecks,
            .defaultStatePath,
            .telemetryUpload,
            .runtimeMutationExpansion
        ]
    }

    private func hasApprovedRecord(id: String?, in approvals: [TeamApprovalRecord]) -> Bool {
        guard let id else {
            return false
        }

        return approvals.contains { approval in
            approval.id == id && approval.decision == .approved
        }
    }

    private func decision(
        profile: TeamPolicyProfile,
        reasonCode: PolicyReasonCode,
        severity: PolicyDecisionSeverity,
        subject: String,
        message: String,
        remediation: String
    ) -> PolicyDecision {
        PolicyDecision(
            category: .team,
            reasonCode: reasonCode,
            severity: severity,
            subject: subject,
            message: message,
            remediation: remediation,
            stableDetailKey: "\(profile.identifier)|\(subject)|\(reasonCode.rawValue)"
        )
    }
}
