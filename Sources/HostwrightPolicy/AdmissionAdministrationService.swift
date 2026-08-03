import Foundation
import HostwrightControlPlane
import HostwrightState

public struct AdmissionAdministrationService: Sendable {
  private let repository: AdmissionRepository
  private let authorizer: RBACAuthorizationEngine

  public init(repository: AdmissionRepository, authorizer: RBACAuthorizationEngine) {
    self.repository = repository
    self.authorizer = authorizer
  }

  public func createPolicy(
    _ policy: AdmissionPolicyRecord, actorSubjectID: String, at: Date
  ) throws -> AdmissionPolicyRecord {
    try require(actorSubjectID, operation: "admission.policy.create", verb: .create, at: at)
    guard policy.createdBySubjectID == actorSubjectID, policy.sourceKind == .extension else {
      throw RBACAuthorizationError.delegationExceedsAuthority
    }
    return try repository.createPolicy(policy)
  }

  public func setPolicyEnabled(
    id: String, enabled: Bool, expectedGeneration: Int,
    actorSubjectID: String, updatedAt: String, at: Date
  ) throws -> AdmissionPolicyRecord {
    try require(
      actorSubjectID, operation: "admission.policy.set-enabled", verb: .update, at: at)
    return try repository.setPolicyEnabled(
      id: id, enabled: enabled, expectedGeneration: expectedGeneration,
      actorSubjectID: actorSubjectID, updatedAt: updatedAt)
  }

  public func deletePolicy(
    id: String, expectedGeneration: Int, actorSubjectID: String, at: Date
  ) throws {
    try require(actorSubjectID, operation: "admission.policy.delete", verb: .delete, at: at)
    try repository.deletePolicy(id: id, expectedGeneration: expectedGeneration)
  }

  public func createException(
    _ exception: AdmissionExceptionRecord, actorSubjectID: String, at: Date
  ) throws -> AdmissionExceptionRecord {
    try require(
      actorSubjectID, operation: "admission.exception.create", verb: .approve, at: at)
    guard exception.createdBySubjectID == actorSubjectID,
      exception.approvalIdentity == actorSubjectID,
      let expiresAt = ISO8601DateFormatter().date(from: exception.expiresAt),
      expiresAt > at
    else {
      throw RBACAuthorizationError.delegationExceedsAuthority
    }
    return try repository.createException(exception)
  }

  public func deleteException(
    id: String, expectedGeneration: Int, actorSubjectID: String, at: Date
  ) throws {
    try require(
      actorSubjectID, operation: "admission.exception.delete", verb: .delete, at: at)
    try repository.deleteException(id: id, expectedGeneration: expectedGeneration)
  }

  private func require(
    _ subjectID: String, operation: String, verb: RBACVerb, at: Date
  ) throws {
    let decision = try authorizer.decision(
      subjectID: subjectID, operation: operation,
      target: RBACAuthorizationTarget(
        resource: .policy, verb: verb, projectIdentifier: nil,
        resourceIdentifier: nil, profileHash: nil),
      at: at)
    guard decision.effect == .allow else {
      throw RBACAuthorizationError.delegationExceedsAuthority
    }
  }
}
