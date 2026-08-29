import Foundation
import HostwrightControlPlane
import HostwrightState

public struct WorkloadProfileAdministrationService: Sendable {
  private let repository: WorkloadProfileRepository
  private let authorizer: RBACAuthorizationEngine

  public init(repository: WorkloadProfileRepository, authorizer: RBACAuthorizationEngine) {
    self.repository = repository
    self.authorizer = authorizer
  }

  public func create(
    _ profile: WorkloadProfile, approval: WorkloadProfileWeakeningApproval?,
    actorSubjectID: String, at: Date
  ) throws -> WorkloadProfileRecord {
    try require(actorSubjectID, operation: "profile.create", verb: .create, profileHash: nil, at: at)
    let engine = WorkloadProfilePolicyEngine(repository: repository)
    let proposal = try engine.proposedResolution(profile)
    if let parentID = profile.parent {
      let parent = try engine.resolve(id: parentID)
      let reasons = WorkloadProfilePolicyEngine.weakeningReasons(
        candidate: proposal.profile, base: parent.profile)
      try authorizeWeakeningIfNeeded(
        reasons: reasons, profile: profile, baseSHA: parent.profileSHA256,
        candidateSHA: proposal.profileSHA256, approval: approval,
        actorSubjectID: actorSubjectID, at: at)
    } else if approval != nil {
      throw WorkloadProfilePolicyError.invalidWeakeningApproval
    }
    let timestamp = ISO8601DateFormatter().string(from: at)
    return try repository.create(
      WorkloadProfileRecord(
        profile: profile, createdBySubjectID: actorSubjectID,
        createdAt: timestamp, updatedAt: timestamp))
  }

  public func update(
    _ profile: WorkloadProfile, expectedGeneration: Int,
    approval: WorkloadProfileWeakeningApproval?, actorSubjectID: String, at: Date
  ) throws -> WorkloadProfileRecord {
    guard try repository.profile(id: profile.identifier) != nil else {
      throw WorkloadProfilePolicyError.missingProfile(profile.identifier)
    }
    let engine = WorkloadProfilePolicyEngine(repository: repository)
    let existingEffective = try engine.resolve(id: profile.identifier)
    try require(
      actorSubjectID, operation: "profile.update", verb: .update,
      profileHash: existingEffective.profileSHA256, at: at)
    let proposal = try engine.proposedResolution(profile)
    let reasons = WorkloadProfilePolicyEngine.weakeningReasons(
      candidate: proposal.profile, base: existingEffective.profile)
    try authorizeWeakeningIfNeeded(
      reasons: Array(Set(reasons)).sorted(), profile: profile,
      baseSHA: existingEffective.profileSHA256, candidateSHA: proposal.profileSHA256,
      approval: approval, actorSubjectID: actorSubjectID, at: at)
    return try repository.update(
      profile: profile, expectedGeneration: expectedGeneration,
      actorSubjectID: actorSubjectID, updatedAt: ISO8601DateFormatter().string(from: at))
  }

  public func delete(
    id: String, expectedGeneration: Int, actorSubjectID: String, at: Date
  ) throws {
    let existing = try repository.profile(id: id)
    try require(
      actorSubjectID, operation: "profile.delete", verb: .delete,
      profileHash: existing?.profileSHA256, at: at)
    try repository.delete(id: id, expectedGeneration: expectedGeneration)
  }

  private func authorizeWeakeningIfNeeded(
    reasons: [String], profile: WorkloadProfile, baseSHA: String, candidateSHA: String,
    approval: WorkloadProfileWeakeningApproval?, actorSubjectID: String, at: Date
  ) throws {
    guard !reasons.isEmpty else {
      guard approval == nil else { throw WorkloadProfilePolicyError.invalidWeakeningApproval }
      return
    }
    guard let approval, approval.profileIdentifier == profile.identifier,
      approval.baseProfileSHA256 == baseSHA, approval.candidateProfileSHA256 == candidateSHA,
      approval.approvalIdentity == actorSubjectID,
      let expiresAt = ISO8601DateFormatter().date(from: approval.expiresAt), expiresAt > at
    else { throw WorkloadProfilePolicyError.weakeningRequiresApproval(reasons) }
    try require(
      actorSubjectID, operation: "profile.weaken", verb: .approve,
      profileHash: candidateSHA, at: at)
  }

  private func require(
    _ subjectID: String, operation: String, verb: RBACVerb, profileHash: String?, at: Date
  ) throws {
    let decision = try authorizer.decision(
      subjectID: subjectID, operation: operation,
      target: RBACAuthorizationTarget(
        resource: .profile, verb: verb, projectIdentifier: nil,
        resourceIdentifier: nil, profileHash: profileHash), at: at)
    guard decision.effect == .allow else {
      throw RBACAuthorizationError.delegationExceedsAuthority
    }
  }
}
