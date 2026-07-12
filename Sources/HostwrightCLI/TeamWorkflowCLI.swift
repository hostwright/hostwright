import HostwrightCore
import HostwrightManifest
import HostwrightPolicy

struct TeamValidatedManifest {
    let manifest: HostwrightManifest
    let profileArtifact: TeamProfileArtifact?
    let manifestHash: String?

    var profileIdentifier: String? {
        profileArtifact?.profile.identifier
    }

    var profileHash: String? {
        profileArtifact?.profileHash
    }

    func previewBinding(planHash: String) -> TeamWorkflowBinding? {
        guard let profileArtifact, let manifestHash else {
            return nil
        }
        return TeamWorkflowBinding(
            profileIdentifier: profileArtifact.profile.identifier,
            profileHash: profileArtifact.profileHash,
            manifestHash: manifestHash,
            planHash: planHash
        )
    }
}

func hostwrightValidatedManifest(
    text: String,
    teamProfilePath: String?,
    environment: CLIEnvironment
) throws -> TeamValidatedManifest {
    guard let teamProfilePath else {
        return TeamValidatedManifest(
            manifest: try ManifestValidator.validated(text),
            profileArtifact: nil,
            manifestHash: nil
        )
    }

    let profileText = try hostwrightReadLocalText(path: teamProfilePath, role: "team profile", environment: environment)
    let artifact = try TeamWorkflowDocumentParser.parseProfile(profileText)
    try requireAllowedProfile(artifact.profile)

    var manifest = try ManifestParser.parse(text)
    if artifact.profile.requiresImageDigest {
        manifest.imagePolicy = .requireDigest
    }
    let issues = ManifestValidator.validate(manifest)
    if !issues.isEmpty {
        throw ManifestParseError.failed(issues)
    }

    return TeamValidatedManifest(
        manifest: manifest,
        profileArtifact: artifact,
        manifestHash: TeamWorkflowDocumentParser.manifestHash(text)
    )
}

func hostwrightApprovedBinding(
    approvalRecordPath: String,
    scope: TeamApprovalScope,
    validatedManifest: TeamValidatedManifest,
    planHash: String,
    environment: CLIEnvironment
) throws -> TeamWorkflowBinding {
    guard let profileArtifact = validatedManifest.profileArtifact,
          let manifestHash = validatedManifest.manifestHash
    else {
        throw HostwrightDiagnostic(
            code: .teamApprovalInvalid,
            message: "An approval record requires an explicitly loaded team profile."
        )
    }

    let text = try hostwrightReadLocalText(path: approvalRecordPath, role: "approval record", environment: environment)
    let artifact = try TeamWorkflowDocumentParser.parseApproval(text)
    let decisions = TeamWorkflowPolicyEvaluator.default.evaluate(
        artifact.approval,
        expected: TeamApprovalExpectation(
            scope: scope,
            profileHash: profileArtifact.profileHash,
            manifestHash: manifestHash,
            planHash: planHash
        )
    )
    let blockers = decisions.filter { $0.severity == .blocker }
    if !blockers.isEmpty {
        let bindingReasons: Set<PolicyReasonCode> = [.teamApprovalBindingMismatch, .teamApprovalScopeMismatch]
        let code: HostwrightErrorCode = blockers.contains { bindingReasons.contains($0.reasonCode) }
            ? .teamBindingMismatch
            : .teamApprovalInvalid
        throw HostwrightDiagnostic(
            code: code,
            message: blockers.map { "\($0.reasonCode.rawValue): \($0.message)" }.joined(separator: " ")
        )
    }

    return TeamWorkflowBinding(
        profileIdentifier: profileArtifact.profile.identifier,
        profileHash: profileArtifact.profileHash,
        manifestHash: manifestHash,
        planHash: planHash,
        approvalID: artifact.approval.id,
        approvalHash: artifact.approvalHash,
        approvalReviewer: artifact.approval.reviewer,
        approvalRecordedAt: artifact.approval.recordedAt,
        approvalScope: artifact.approval.scope
    )
}

func hostwrightTeamProfileText(_ validatedManifest: TeamValidatedManifest, planHash: String? = nil) -> String {
    guard let profileIdentifier = validatedManifest.profileIdentifier,
          let profileHash = validatedManifest.profileHash,
          let manifestHash = validatedManifest.manifestHash
    else {
        return ""
    }

    var lines = [
        "Team profile: \(profileIdentifier)",
        "Profile hash: \(profileHash)",
        "Manifest hash: \(manifestHash)"
    ]
    if let planHash {
        lines.append("Plan hash binding: \(planHash)")
        lines.append("Approval required for profile-aware mutation: yes")
    }
    return lines.joined(separator: "\n") + "\n"
}

func hostwrightTeamBindingPayload(_ binding: TeamWorkflowBinding?) -> [String: Any] {
    guard let binding else {
        return [:]
    }
    var payload: [String: Any] = [
        "profileIdentifier": binding.profileIdentifier,
        "profileHash": binding.profileHash,
        "manifestHash": binding.manifestHash,
        "planHash": binding.planHash
    ]
    if let approvalID = binding.approvalID {
        payload["approvalID"] = approvalID
    }
    if let approvalHash = binding.approvalHash {
        payload["approvalHash"] = approvalHash
    }
    if let approvalReviewer = binding.approvalReviewer {
        payload["approvalReviewer"] = approvalReviewer
    }
    if let approvalRecordedAt = binding.approvalRecordedAt {
        payload["approvalRecordedAt"] = approvalRecordedAt
    }
    if let approvalScope = binding.approvalScope {
        payload["approvalScope"] = approvalScope.rawValue
    }
    return payload
}

private func requireAllowedProfile(_ profile: TeamPolicyProfile) throws {
    let blockers = TeamWorkflowPolicyEvaluator.default.evaluate(profile).filter { $0.severity == .blocker }
    if !blockers.isEmpty {
        throw HostwrightDiagnostic(
            code: .teamProfileInvalid,
            message: blockers.map { "\($0.reasonCode.rawValue): \($0.message)" }.joined(separator: " ")
        )
    }
}
