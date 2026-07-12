import Foundation

public enum TeamWorkflowGate: String, CaseIterable, Codable, Equatable, Sendable {
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

public enum TeamPolicyRequirement: String, CaseIterable, Codable, Equatable, Sendable {
    case requireImageDigest
    case requireManifestReview
}

public struct TeamPolicyProfile: Codable, Equatable, Sendable {
    public static let currentAPIVersion = 1
    public static let kind = "HostwrightTeamProfile"

    public let kind: String
    public let apiVersion: Int
    public let identifier: String
    public let displayName: String
    public let optIn: Bool
    public let requiredGates: [TeamWorkflowGate]
    public let requirements: [TeamPolicyRequirement]

    public init(
        kind: String = Self.kind,
        apiVersion: Int = Self.currentAPIVersion,
        identifier: String,
        displayName: String,
        optIn: Bool,
        requiredGates: [TeamWorkflowGate],
        requirements: [TeamPolicyRequirement] = []
    ) {
        self.kind = kind
        self.apiVersion = apiVersion
        self.identifier = identifier
        self.displayName = displayName
        self.optIn = optIn
        self.requiredGates = requiredGates
        self.requirements = requirements
    }

    public var requiresImageDigest: Bool {
        requirements.contains(.requireImageDigest)
    }
}

public enum TeamApprovalDecision: String, Codable, Equatable, Sendable {
    case approved
    case rejected
}

public enum TeamApprovalScope: String, Codable, Equatable, Sendable {
    case apply
    case cleanup
}

public struct TeamApprovalRecord: Codable, Equatable, Sendable {
    public static let currentAPIVersion = 1
    public static let kind = "HostwrightApprovalRecord"

    public let kind: String
    public let apiVersion: Int
    public let id: String
    public let reviewer: String
    public let decision: TeamApprovalDecision
    public let scope: TeamApprovalScope
    public let recordedAt: String
    public let profileHash: String
    public let manifestHash: String
    public let planHash: String

    public init(
        kind: String = Self.kind,
        apiVersion: Int = Self.currentAPIVersion,
        id: String,
        reviewer: String,
        decision: TeamApprovalDecision,
        scope: TeamApprovalScope,
        recordedAt: String,
        profileHash: String,
        manifestHash: String,
        planHash: String
    ) {
        self.kind = kind
        self.apiVersion = apiVersion
        self.id = id
        self.reviewer = reviewer
        self.decision = decision
        self.scope = scope
        self.recordedAt = recordedAt
        self.profileHash = profileHash
        self.manifestHash = manifestHash
        self.planHash = planHash
    }
}

public struct TeamApprovalExpectation: Equatable, Sendable {
    public let scope: TeamApprovalScope
    public let profileHash: String
    public let manifestHash: String
    public let planHash: String

    public init(scope: TeamApprovalScope, profileHash: String, manifestHash: String, planHash: String) {
        self.scope = scope
        self.profileHash = profileHash
        self.manifestHash = manifestHash
        self.planHash = planHash
    }
}

public struct TeamWorkflowPolicyEvaluator: Equatable, Sendable {
    public init() {}

    public static let `default` = TeamWorkflowPolicyEvaluator()

    public func evaluate(_ profile: TeamPolicyProfile) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []
        let identifier = profile.identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        if identifier.isEmpty || identifier.range(of: #"^[a-z0-9]([a-z0-9.-]{0,126}[a-z0-9])?$"#, options: .regularExpression) == nil {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileMissingIdentity,
                    severity: .blocker,
                    subject: "identity",
                    message: "Team policy profiles must include a stable lowercase identifier.",
                    remediation: "Use lowercase letters, numbers, dots, or hyphens without leading or trailing punctuation."
                )
            )
        }

        if profile.kind != TeamPolicyProfile.kind {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileInvalidKind,
                    severity: .blocker,
                    subject: "kind",
                    message: "Team policy profile kind '\(profile.kind)' is not supported.",
                    remediation: "Use kind '\(TeamPolicyProfile.kind)'."
                )
            )
        }

        if profile.apiVersion != TeamPolicyProfile.currentAPIVersion {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileUnsupportedVersion,
                    severity: .blocker,
                    subject: "apiVersion",
                    message: "Team policy profile API version \(profile.apiVersion) is not supported.",
                    remediation: "Use API version \(TeamPolicyProfile.currentAPIVersion) until a later compatibility policy is approved."
                )
            )
        }

        if profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileInvalidDisplayName,
                    severity: .blocker,
                    subject: "displayName",
                    message: "Team policy profiles must include a non-empty display name.",
                    remediation: "Declare a local display name for operator review."
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
                    remediation: "Set optIn to true in the explicitly selected local profile."
                )
            )
        }

        let gateCounts = Dictionary(grouping: profile.requiredGates, by: { $0 }).mapValues(\.count)
        for gate in TeamWorkflowGate.allCases where gateCounts[gate] == nil {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileMissingRequiredGate,
                    severity: .blocker,
                    subject: gate.rawValue,
                    message: "Team policy profile is missing required gate '\(gate.rawValue)'.",
                    remediation: "Declare every required Hostwright safety gate; team policy cannot remove core boundaries."
                )
            )
        }
        for (gate, count) in gateCounts where count > 1 {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileDuplicateGate,
                    severity: .blocker,
                    subject: gate.rawValue,
                    message: "Team policy profile repeats required gate '\(gate.rawValue)'.",
                    remediation: "Declare each required gate exactly once."
                )
            )
        }

        let requirementCounts = Dictionary(grouping: profile.requirements, by: { $0 }).mapValues(\.count)
        for (requirement, count) in requirementCounts where count > 1 {
            decisions.append(
                decision(
                    profile: profile,
                    reasonCode: .teamProfileDuplicateRequirement,
                    severity: .blocker,
                    subject: requirement.rawValue,
                    message: "Team policy profile repeats stricter requirement '\(requirement.rawValue)'.",
                    remediation: "Declare each stricter requirement at most once."
                )
            )
        }

        if decisions.isEmpty {
            if profile.requirements.isEmpty {
                decisions.append(
                    decision(
                        profile: profile,
                        reasonCode: .teamProfileDeclared,
                        severity: .allow,
                        subject: identifier,
                        message: "Team policy profile '\(identifier)' is local, opt-in, and preserves required Hostwright gates.",
                        remediation: "Use explicit profile and approval paths for reviewed team operations."
                    )
                )
            } else {
                decisions.append(contentsOf: profile.requirements.map { requirement in
                    decision(
                        profile: profile,
                        reasonCode: .teamRequirementDeclared,
                        severity: .allow,
                        subject: requirement.rawValue,
                        message: "Team policy profile requires stricter policy '\(requirement.rawValue)'.",
                        remediation: "Keep the stricter requirement in force for every command using this profile."
                    )
                })
            }
        }

        return decisions.sorted { $0.orderingKey < $1.orderingKey }
    }

    public func evaluate(_ approval: TeamApprovalRecord, expected: TeamApprovalExpectation) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []

        if approval.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            approval.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decisions.append(approvalDecision(.teamApprovalMissingIdentity, "identity", "Approval records require non-empty id and reviewer fields."))
        }
        if approval.kind != TeamApprovalRecord.kind {
            decisions.append(approvalDecision(.teamApprovalInvalidKind, "kind", "Approval record kind '\(approval.kind)' is not supported."))
        }
        if approval.apiVersion != TeamApprovalRecord.currentAPIVersion {
            decisions.append(approvalDecision(.teamApprovalUnsupportedVersion, "apiVersion", "Approval record API version \(approval.apiVersion) is not supported."))
        }
        if approval.decision != .approved {
            decisions.append(approvalDecision(.teamApprovalRejected, "decision", "Only an approved local review record can authorize a profile-aware mutation."))
        }
        if approval.scope != expected.scope {
            decisions.append(approvalDecision(.teamApprovalScopeMismatch, "scope", "Approval scope '\(approval.scope.rawValue)' does not match '\(expected.scope.rawValue)'."))
        }
        if ISO8601DateFormatter().date(from: approval.recordedAt) == nil {
            decisions.append(approvalDecision(.teamApprovalInvalidTimestamp, "recordedAt", "Approval recordedAt must be an ISO-8601 timestamp."))
        }

        let bindings = [
            ("profileHash", approval.profileHash, expected.profileHash),
            ("manifestHash", approval.manifestHash, expected.manifestHash),
            ("planHash", approval.planHash, expected.planHash)
        ]
        for (field, actual, wanted) in bindings where actual != wanted {
            decisions.append(approvalDecision(.teamApprovalBindingMismatch, field, "Approval \(field) does not match the current operation."))
        }

        if decisions.isEmpty {
            decisions.append(
                PolicyDecision(
                    category: .team,
                    reasonCode: .teamApprovalRecorded,
                    severity: .allow,
                    subject: approval.id,
                    message: "Approval record is bound to the exact profile, manifest, plan, and operation scope.",
                    remediation: "Preserve the approval hash in the local append-only audit trail.",
                    stableDetailKey: approval.id
                )
            )
        }
        return decisions.sorted { $0.orderingKey < $1.orderingKey }
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

    private func approvalDecision(_ reasonCode: PolicyReasonCode, _ subject: String, _ message: String) -> PolicyDecision {
        PolicyDecision(
            category: .team,
            reasonCode: reasonCode,
            severity: .blocker,
            subject: subject,
            message: message,
            remediation: "Create a new explicit approval record for the exact current operation; approvals never bypass core safety gates.",
            stableDetailKey: "\(subject)|\(reasonCode.rawValue)"
        )
    }
}
