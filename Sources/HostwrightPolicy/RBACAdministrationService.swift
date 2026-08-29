import Foundation
import HostwrightControlPlane
import HostwrightState

public struct RBACAdministrationService: Sendable {
  private let repository: RBACRepository
  private let authorizer: RBACAuthorizationEngine

  public init(repository: RBACRepository, authorizer: RBACAuthorizationEngine) {
    self.repository = repository
    self.authorizer = authorizer
  }

  public func createRole(
    _ role: RBACRoleRecord,
    actorSubjectID: String,
    timestamp: String
  ) throws -> RBACRoleRecord {
    let at = try date(timestamp)
    try requireManagementAuthority(
      actorSubjectID: actorSubjectID, operation: "rbac.role.create", verb: .create, at: at)
    try requireGrantAuthority(
      actorSubjectID: actorSubjectID, rules: role.rules, outerScope: .init(kind: .global),
      at: at)
    return try repository.createCustomRole(
      role, actorSubjectID: actorSubjectID, timestamp: timestamp)
  }

  public func updateRole(
    _ role: RBACRoleRecord,
    expectedGeneration: Int,
    actorSubjectID: String,
    timestamp: String
  ) throws -> RBACRoleRecord {
    let at = try date(timestamp)
    try requireManagementAuthority(
      actorSubjectID: actorSubjectID, operation: "rbac.role.update", verb: .update, at: at)
    try requireGrantAuthority(
      actorSubjectID: actorSubjectID, rules: role.rules, outerScope: .init(kind: .global),
      at: at)
    return try repository.updateCustomRole(
      role, expectedGeneration: expectedGeneration, actorSubjectID: actorSubjectID,
      timestamp: timestamp)
  }

  public func deleteRole(
    id: String,
    expectedGeneration: Int,
    actorSubjectID: String,
    at: Date
  ) throws {
    try requireManagementAuthority(
      actorSubjectID: actorSubjectID, operation: "rbac.role.delete", verb: .delete, at: at)
    try repository.deleteCustomRole(id: id, expectedGeneration: expectedGeneration)
  }

  public func createBinding(
    _ binding: RBACBindingRecord,
    actorSubjectID: String,
    at: Date
  ) throws -> RBACBindingRecord {
    try requireManagementAuthority(
      actorSubjectID: actorSubjectID, operation: "rbac.binding.create", verb: .create, at: at)
    guard binding.createdBySubjectID == actorSubjectID else {
      throw RBACAuthorizationError.delegationExceedsAuthority
    }
    guard let role = try repository.role(id: binding.roleID) else {
      throw StateStoreError.notFound("RBAC role \(binding.roleID) does not exist.")
    }
    if role.roleID == DefaultRole.owner.rawValue {
      guard try isGlobalOwner(actorSubjectID) else {
        throw RBACAuthorizationError.delegationExceedsAuthority
      }
    } else {
      try requireGrantAuthority(
        actorSubjectID: actorSubjectID, rules: role.rules, outerScope: binding.scope, at: at)
    }
    return try repository.createBinding(binding)
  }

  public func deleteBinding(
    id: String,
    expectedGeneration: Int,
    actorSubjectID: String,
    at: Date
  ) throws {
    try requireManagementAuthority(
      actorSubjectID: actorSubjectID, operation: "rbac.binding.delete", verb: .delete,
      at: at)
    guard let binding = try repository.binding(id: id) else {
      throw StateStoreError.notFound("RBAC binding \(id) does not exist.")
    }
    if binding.roleID == DefaultRole.owner.rawValue {
      guard try isGlobalOwner(actorSubjectID) else {
        throw RBACAuthorizationError.delegationExceedsAuthority
      }
    }
    try repository.deleteBinding(id: id, expectedGeneration: expectedGeneration)
  }

  public func createDelegation(
    _ delegation: RBACDelegationRecord,
    actorSubjectID: String,
    at: Date
  ) throws -> RBACDelegationRecord {
    guard delegation.delegatorSubjectID == actorSubjectID,
      !delegation.roleIDs.contains(DefaultRole.owner.rawValue)
    else { throw RBACAuthorizationError.delegationExceedsAuthority }
    guard let expiresAt = ISO8601DateFormatter().date(from: delegation.expiresAt), expiresAt > at
    else { throw RBACAuthorizationError.delegationExceedsAuthority }
    var rules = delegation.delegatedRules
    for roleID in delegation.roleIDs {
      guard let role = try repository.role(id: roleID), !role.builtIn || roleID != "owner" else {
        throw RBACAuthorizationError.delegationExceedsAuthority
      }
      rules += role.rules
    }
    try requireGrantAuthority(
      actorSubjectID: actorSubjectID, rules: rules, outerScope: delegation.scope, at: at)
    return try repository.createDelegation(delegation)
  }

  public func revokeDelegation(
    id: String,
    expectedGeneration: Int,
    actorSubjectID: String,
    revokedAt: String
  ) throws -> RBACDelegationRecord {
    guard let delegation = try repository.delegation(id: id) else {
      throw StateStoreError.notFound("RBAC delegation \(id) does not exist.")
    }
    var mayRevoke = delegation.delegatorSubjectID == actorSubjectID
    if !mayRevoke { mayRevoke = try isGlobalOwner(actorSubjectID) }
    guard mayRevoke else { throw RBACAuthorizationError.delegationExceedsAuthority }
    return try repository.revokeDelegation(
      id: id, expectedGeneration: expectedGeneration, revokedAt: revokedAt)
  }

  private func requireGrantAuthority(
    actorSubjectID: String,
    rules: [RBACRule],
    outerScope: RBACScope,
    at: Date
  ) throws {
    if try isGlobalOwner(actorSubjectID) { return }
    let management = try authorizer.decision(
      subjectID: actorSubjectID,
      operation: "rbac.grant",
      target: RBACAuthorizationTarget(
        resource: .policy, verb: .delegate, projectIdentifier: nil,
        resourceIdentifier: nil, profileHash: nil),
      at: at)
    guard management.effect == .allow else {
      throw RBACAuthorizationError.delegationExceedsAuthority
    }
    for rule in rules where rule.effect == .allow {
      guard rule.conditions.isEmpty else {
        throw RBACAuthorizationError.delegationExceedsAuthority
      }
      let target = try representativeTarget(rule: rule, outerScope: outerScope)
      for resource in rule.resources {
        for verb in rule.verbs {
          let decision = try authorizer.decision(
            subjectID: actorSubjectID,
            operation: "rbac.grant",
            target: RBACAuthorizationTarget(
              resource: resource, verb: verb,
              projectIdentifier: target.projectIdentifier,
              resourceIdentifier: target.resourceIdentifier,
              profileHash: nil),
            at: at
          )
          guard decision.effect == .allow else {
            throw RBACAuthorizationError.delegationExceedsAuthority
          }
        }
      }
    }
  }

  private func requireManagementAuthority(
    actorSubjectID: String,
    operation: String,
    verb: RBACVerb,
    at: Date
  ) throws {
    if try isGlobalOwner(actorSubjectID) { return }
    let decision = try authorizer.decision(
      subjectID: actorSubjectID,
      operation: operation,
      target: RBACAuthorizationTarget(
        resource: .policy, verb: verb, projectIdentifier: nil,
        resourceIdentifier: nil, profileHash: nil),
      at: at)
    guard decision.effect == .allow else {
      throw RBACAuthorizationError.delegationExceedsAuthority
    }
  }

  private func representativeTarget(
    rule: RBACRule,
    outerScope: RBACScope
  ) throws -> RBACAuthorizationTarget {
    let scopes = [outerScope, rule.scope].filter { $0.kind != .global }
    let projects = Set(scopes.filter { $0.kind == .project }.compactMap(\.identifier))
    let resources = Set(scopes.filter { $0.kind == .resource }.compactMap(\.identifier))
    guard projects.count <= 1, resources.count <= 1 else {
      throw RBACAuthorizationError.delegationExceedsAuthority
    }
    return RBACAuthorizationTarget(
      resource: .policy, verb: .get, projectIdentifier: projects.first,
      resourceIdentifier: resources.first, profileHash: nil)
  }

  private func isGlobalOwner(_ subjectID: String) throws -> Bool {
    try repository.listBindings(subjectID: subjectID).contains {
      $0.roleID == DefaultRole.owner.rawValue && $0.scope.kind == .global
    }
  }

  private func date(_ timestamp: String) throws -> Date {
    guard let value = ISO8601DateFormatter().date(from: timestamp) else {
      throw RBACAuthorizationError.invalidTarget
    }
    return value
  }
}
