import CryptoKit
import Foundation
import HostwrightControlPlane
import HostwrightState

public enum RBACAuthorizationError: Error, Equatable, Sendable {
  case invalidTarget
  case invalidPolicyState
  case delegationExceedsAuthority
}

struct RBACAuthorizationTarget: Hashable, Sendable {
  let resource: RBACResource
  let verb: RBACVerb
  let projectIdentifier: String?
  let resourceIdentifier: String?
  let profileHash: String?

  func validate() throws {
    for value in [projectIdentifier, resourceIdentifier] {
      guard value == nil || (!value!.isEmpty && value!.utf8.count <= 128) else {
        throw RBACAuthorizationError.invalidTarget
      }
    }
    guard profileHash == nil
      || profileHash!.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    else { throw RBACAuthorizationError.invalidTarget }
  }
}

public final class RBACAuthorizationEngine: @unchecked Sendable {
  private struct Snapshot: Codable {
    let roles: [RBACRoleRecord]
    let bindings: [RBACBindingRecord]
    let delegations: [RBACDelegationRecord]
  }

  private struct CacheKey: Hashable {
    let subjectID: String
    let operation: String
    let target: RBACAuthorizationTarget
    let snapshotDigest: String
  }

  private let repository: RBACRepository
  private let lock = NSLock()
  private var cachedDecisions: [CacheKey: RBACDecision] = [:]
  private var cachedSnapshotDigest: String?

  public init(repository: RBACRepository) {
    self.repository = repository
  }

  public func authorize(
    subject: LocalSubject,
    request: ControlRequestEnvelope,
    at: Date
  ) throws -> RBACDecision {
    try subject.validate()
    let target = try Self.target(for: request)
    return try decision(
      subjectID: subject.identifier, operation: request.operation, target: target, at: at)
  }

  public func preview(
    subjectID: String,
    request: ControlRequestEnvelope,
    at: Date
  ) throws -> RBACDecision {
    let target = try Self.target(for: request)
    return try decision(subjectID: subjectID, operation: request.operation, target: target, at: at)
  }

  func decision(
    subjectID: String,
    operation: String,
    target: RBACAuthorizationTarget,
    at: Date
  ) throws -> RBACDecision {
    guard !subjectID.isEmpty, subjectID.utf8.count <= 128 else {
      throw RBACAuthorizationError.invalidTarget
    }
    try target.validate()
    let snapshot = Snapshot(
      roles: try repository.listRoles(),
      bindings: try repository.listBindings(),
      delegations: try repository.listDelegations()
    )
    let digest = try Self.digest(snapshot)
    let cacheable = !Self.hasTemporalAuthority(snapshot)
    let key = CacheKey(
      subjectID: subjectID, operation: operation, target: target,
      snapshotDigest: digest
    )
    lock.lock()
    if cachedSnapshotDigest != digest {
      cachedDecisions.removeAll(keepingCapacity: true)
      cachedSnapshotDigest = digest
    }
    let cached = cacheable ? cachedDecisions[key] : nil
    lock.unlock()
    let decision: RBACDecision
    if let cached {
      decision = cached
    } else {
      decision = try Self.evaluate(
        subjectID: subjectID, operation: operation, target: target,
        snapshot: snapshot, at: at
      )
      if cacheable {
        lock.lock()
        cachedDecisions[key] = decision
        lock.unlock()
      }
    }
    try decision.validate()
    return decision
  }

  public func resetCache() {
    lock.lock()
    cachedDecisions.removeAll(keepingCapacity: false)
    cachedSnapshotDigest = nil
    lock.unlock()
  }

  static func target(for request: ControlRequestEnvelope) throws -> RBACAuthorizationTarget {
    let fields: [String: ControlPlaneJSONValue]
    if let body = request.body {
      guard case .object(let value) = body else { throw RBACAuthorizationError.invalidTarget }
      fields = value
    } else {
      fields = [:]
    }
    let project = try string(in: fields, keys: ["projectUUID", "projectID", "project"])
    let resource = try string(
      in: fields,
      keys: ["resourceUUID", "resourceID", "serviceUUID", "service", "identifier"])
    let profileHash = try string(in: fields, keys: ["profileHash"])
    let subcommand = try string(in: fields, keys: ["subcommand", "action", "verb"])

    let resourceKind: RBACResource
    let verb: RBACVerb
    switch request.operation {
    case "plan": (resourceKind, verb) = (.project, .plan)
    case "status": (resourceKind, verb) = (.project, .get)
    case "events": (resourceKind, verb) = (.observability, .list)
    case "recovery": (resourceKind, verb) = (.state, .update)
    case "doctor", "capabilities": (resourceKind, verb) = (.daemon, .get)
    case "up", "run", "start": (resourceKind, verb) = (.service, .start)
    case "down", "stop": (resourceKind, verb) = (.service, .stop)
    case "restart": (resourceKind, verb) = (.service, .restart)
    case "rm": (resourceKind, verb) = (.service, .delete)
    case "update": (resourceKind, verb) = (.service, .update)
    case "image": (resourceKind, verb) = (.image, mappedVerb(subcommand, default: .get))
    case "registry": (resourceKind, verb) = (.registry, mappedVerb(subcommand, default: .get))
    case "volume": (resourceKind, verb) = (.volume, mappedVerb(subcommand, default: .get))
    case "audit.verify", "audit.export": (resourceKind, verb) = (.audit, .get)
    case "rbac.preview": (resourceKind, verb) = (.policy, .get)
    case "rbac.role.list", "rbac.binding.list", "rbac.delegation.list":
      (resourceKind, verb) = (.policy, .list)
    case "rbac.role.create", "rbac.binding.create": (resourceKind, verb) = (.policy, .create)
    case "rbac.role.update": (resourceKind, verb) = (.policy, .update)
    case "rbac.role.delete", "rbac.binding.delete": (resourceKind, verb) = (.policy, .delete)
    case "rbac.delegation.create": (resourceKind, verb) = (.policy, .delegate)
    case "rbac.delegation.revoke": (resourceKind, verb) = (.policy, .update)
    default: (resourceKind, verb) = (.daemon, .admin)
    }
    return RBACAuthorizationTarget(
      resource: resourceKind, verb: verb, projectIdentifier: project,
      resourceIdentifier: resource, profileHash: profileHash)
  }

  private static func mappedVerb(_ value: String?, default fallback: RBACVerb) -> RBACVerb {
    switch value {
    case "list": return .list
    case "get", "inspect", "status", "verify": return .get
    case "create", "pull", "import": return .create
    case "update", "push", "tag": return .update
    case "delete", "remove", "rm", "prune": return .delete
    case "approve": return .approve
    default: return fallback
    }
  }

  private static func string(
    in fields: [String: ControlPlaneJSONValue], keys: [String]
  ) throws -> String? {
    var values = Set<String>()
    for key in keys {
      guard let field = fields[key] else { continue }
      guard case .string(let value) = field, !value.isEmpty, value.utf8.count <= 128 else {
        throw RBACAuthorizationError.invalidTarget
      }
      values.insert(value)
    }
    guard values.count <= 1 else { throw RBACAuthorizationError.invalidTarget }
    return values.first
  }

  private static func evaluate(
    subjectID: String,
    operation: String,
    target: RBACAuthorizationTarget,
    snapshot: Snapshot,
    at: Date
  ) throws -> RBACDecision {
    let roles = Dictionary(uniqueKeysWithValues: snapshot.roles.map { ($0.roleID, $0) })
    guard roles.count == snapshot.roles.count else { throw RBACAuthorizationError.invalidPolicyState }
    var matchingRules: [RBACRule] = []
    for binding in snapshot.bindings where binding.subjectID == subjectID {
      guard scope(binding.scope, matches: target), let role = roles[binding.roleID] else { continue }
      matchingRules += role.rules.filter {
        rule($0, matches: target, operation: operation, at: at)
      }
    }
    for delegation in snapshot.delegations
    where delegation.delegateSubjectID == subjectID && delegation.revokedAt == nil {
      guard let expiry = ISO8601DateFormatter().date(from: delegation.expiresAt), expiry > at,
        scope(delegation.scope, matches: target)
      else { continue }
      for roleID in delegation.roleIDs {
        guard roleID != DefaultRole.owner.rawValue, let role = roles[roleID] else {
          throw RBACAuthorizationError.invalidPolicyState
        }
        matchingRules += role.rules.filter {
          rule($0, matches: target, operation: operation, at: at)
        }
      }
      matchingRules += delegation.delegatedRules.filter {
        rule($0, matches: target, operation: operation, at: at)
      }
    }
    let denies = matchingRules.filter { $0.effect == .deny }.map(\.identifier).sorted()
    if !denies.isEmpty {
      return RBACDecision(
        effect: .deny, ruleIdentifiers: denies, reasonCode: "authorization.explicit-deny")
    }
    let allows = matchingRules.filter { $0.effect == .allow }.map(\.identifier).sorted()
    if !allows.isEmpty {
      return RBACDecision(
        effect: .allow, ruleIdentifiers: allows, reasonCode: "authorization.allowed")
    }
    return RBACDecision(
      effect: .deny, ruleIdentifiers: [], reasonCode: "authorization.no-allow")
  }

  private static func rule(
    _ rule: RBACRule,
    matches target: RBACAuthorizationTarget,
    operation: String,
    at: Date
  ) -> Bool {
    guard rule.resources.contains(target.resource), rule.verbs.contains(target.verb),
      scope(rule.scope, matches: target)
    else { return false }
    for condition in rule.conditions {
      switch condition.kind {
      case .project:
        guard condition.value == target.projectIdentifier else { return false }
      case .resource:
        guard condition.value == target.resourceIdentifier else { return false }
      case .operation:
        guard condition.value == operation else { return false }
      case .profileHash:
        guard condition.value == target.profileHash else { return false }
      case .expiresAt:
        guard let expiry = ISO8601DateFormatter().date(from: condition.value), expiry > at else {
          return false
        }
      }
    }
    return true
  }

  private static func scope(_ scope: RBACScope, matches target: RBACAuthorizationTarget) -> Bool {
    switch scope.kind {
    case .global: return scope.identifier == nil
    case .project: return scope.identifier == target.projectIdentifier
    case .resource: return scope.identifier == target.resourceIdentifier
    }
  }

  private static func digest(_ snapshot: Snapshot) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(snapshot)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func hasTemporalAuthority(_ snapshot: Snapshot) -> Bool {
    if !snapshot.delegations.isEmpty { return true }
    return snapshot.roles.contains { role in
      role.rules.contains { rule in
        rule.conditions.contains { $0.kind == .expiresAt }
      }
    }
  }
}
