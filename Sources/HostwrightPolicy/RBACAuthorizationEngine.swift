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
    authoritativeProjectIdentifier: String? = nil,
    authoritativeResourceIdentifier: String? = nil,
    at: Date
  ) throws -> RBACDecision {
    try subject.validate()
    let requested = try Self.target(for: request)
    guard requested.projectIdentifier == nil || authoritativeProjectIdentifier == nil
      || requested.projectIdentifier == authoritativeProjectIdentifier,
      requested.resourceIdentifier == nil || authoritativeResourceIdentifier == nil
      || requested.resourceIdentifier == authoritativeResourceIdentifier
    else { throw RBACAuthorizationError.invalidTarget }
    let target = RBACAuthorizationTarget(
      resource: requested.resource,
      verb: requested.verb,
      projectIdentifier: authoritativeProjectIdentifier ?? requested.projectIdentifier,
      resourceIdentifier: authoritativeResourceIdentifier ?? requested.resourceIdentifier,
      profileHash: requested.profileHash
    )
    return try decision(
      subjectID: subject.identifier, operation: request.operation, target: target, at: at)
  }

  public func authorizeStream(
    subject: LocalSubject,
    request: ControlStreamOpenRequest,
    projectIdentifier authoritativeProjectIdentifier: String? = nil,
    at: Date
  ) throws -> RBACDecision {
    try subject.validate()
    try request.validate()
    let requestedProjectIdentifier: String?
    if case .object(let fields) = request.filter,
      case .string(let value) = fields["projectID"]
    {
      requestedProjectIdentifier = value
    } else {
      requestedProjectIdentifier = nil
    }
    if request.source != .events {
      guard requestedProjectIdentifier == nil || authoritativeProjectIdentifier == nil
        || requestedProjectIdentifier == authoritativeProjectIdentifier
      else { throw RBACAuthorizationError.invalidTarget }
    }
    let projectIdentifier = authoritativeProjectIdentifier ?? requestedProjectIdentifier
    let resource: RBACResource
    let verb: RBACVerb
    switch request.source {
    case .logs, .events, .metrics, .traces:
      (resource, verb) = (.observability, .watch)
    case .operation, .state:
      (resource, verb) = (.state, .watch)
    case .attach, .exec:
      (resource, verb) = (.runtime, .execute)
    }
    return try decision(
      subjectID: subject.identifier,
      operation: "stream.\(request.source.rawValue)",
      target: RBACAuthorizationTarget(
        resource: resource,
        verb: verb,
        projectIdentifier: projectIdentifier,
        resourceIdentifier: request.target,
        profileHash: nil
      ),
      at: at
    )
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
    let commandOperation = try string(in: fields, keys: ["commandOperation"])
    let declaredMutation = try boolean(in: fields, key: "mutating")
    let localControlIntent = try localControlAuthorizationIntent(
      operation: request.operation,
      fields: fields
    )
    guard subcommand == nil || localControlIntent == nil else {
      throw RBACAuthorizationError.invalidTarget
    }
    let isSchedulerOperation = request.operation.hasPrefix("scheduler.")
    if isSchedulerOperation {
      // Scheduler reads are never global: the daemon wire contract supplies
      // the authoritative top-level project scope before this mapping runs.
      guard project != nil else { throw RBACAuthorizationError.invalidTarget }
    }

    let resourceKind: RBACResource
    var verb: RBACVerb
    switch request.operation {
    case "cli.stream.prepare":
      switch commandOperation {
      case "logs", "events": (resourceKind, verb) = (.observability, .watch)
      case "exec", "attach": (resourceKind, verb) = (.runtime, .execute)
      default: throw RBACAuthorizationError.invalidTarget
      }
    case "plan": (resourceKind, verb) = (.project, .plan)
    case "scheduler.plan", "scheduler.simulate": (resourceKind, verb) = (.project, .plan)
    case "scheduler.status", "scheduler.explain": (resourceKind, verb) = (.project, .get)
    case "scheduler.apply": (resourceKind, verb) = (.project, .update)
    case "status": (resourceKind, verb) = (.project, .get)
    case "events": (resourceKind, verb) = (.observability, .list)
    case "recovery":
      (resourceKind, verb) = (.state, mappedVerb(subcommand, default: .update))
    case "doctor", "capabilities", "observability": (resourceKind, verb) = (.daemon, .get)
    case "runtime":
      (resourceKind, verb) = (.runtime, mappedVerb(subcommand, default: .get))
    case "paths": (resourceKind, verb) = (.state, .get)
    case "state": (resourceKind, verb) = (.state, mappedVerb(subcommand, default: .admin))
    case "secret":
      (resourceKind, verb) = (.secretMetadata, mappedVerb(subcommand, default: .admin))
    case "daemon": (resourceKind, verb) = (.daemon, mappedVerb(subcommand, default: .admin))
    case "restart-budget", "maintenance", "ownership":
      (resourceKind, verb) = (.state, mappedVerb(subcommand, default: .admin))
    case "metrics", "traces", "diagnostics":
      (resourceKind, verb) = (.observability, mappedVerb(subcommand, default: .get))
    case "migrate", "validate", "import-stack": (resourceKind, verb) = (.project, .plan)
    case "init": (resourceKind, verb) = (.project, .create)
    case "apply": (resourceKind, verb) = (.project, .update)
    case "exec", "attach", "copy", "export": (resourceKind, verb) = (.runtime, .execute)
    case "inspect", "stats": (resourceKind, verb) = (.runtime, .get)
    case "logs": (resourceKind, verb) = (.observability, .watch)
    case "cleanup": (resourceKind, verb) = (.project, .delete)
    case "benchmark": (resourceKind, verb) = (.runtime, .execute)
    case "extension": (resourceKind, verb) = (.plugin, .get)
    case "up", "run", "start": (resourceKind, verb) = (.service, .start)
    case "down", "stop": (resourceKind, verb) = (.service, .stop)
    case "restart": (resourceKind, verb) = (.service, .restart)
    case "rm": (resourceKind, verb) = (.service, .delete)
    case "update": (resourceKind, verb) = (.service, .update)
    case "image":
      (resourceKind, verb) = (
        .image,
        localControlIntent?.verb
          ?? (subcommand == nil ? .admin : mappedVerb(subcommand, default: .get))
      )
    case "registry":
      (resourceKind, verb) = (
        .registry,
        localControlIntent?.verb
          ?? (subcommand == nil ? .admin : mappedVerb(subcommand, default: .get))
      )
    case "volume":
      (resourceKind, verb) = (
        .volume,
        localControlIntent?.verb
          ?? (subcommand == nil ? .admin : mappedVerb(subcommand, default: .get))
      )
    case "audit.verify", "audit.export": (resourceKind, verb) = (.audit, .get)
    case "rbac.preview": (resourceKind, verb) = (.policy, .get)
    case "rbac.role.list", "rbac.binding.list", "rbac.delegation.list":
      (resourceKind, verb) = (.policy, .list)
    case "rbac.role.create", "rbac.binding.create": (resourceKind, verb) = (.policy, .create)
    case "rbac.role.update": (resourceKind, verb) = (.policy, .update)
    case "rbac.role.delete", "rbac.binding.delete": (resourceKind, verb) = (.policy, .delete)
    case "rbac.delegation.create": (resourceKind, verb) = (.policy, .delegate)
    case "rbac.delegation.revoke": (resourceKind, verb) = (.policy, .update)
    case "admission.preview": (resourceKind, verb) = (.policy, .get)
    case "admission.policy.list", "admission.exception.list":
      (resourceKind, verb) = (.policy, .list)
    case "admission.policy.create": (resourceKind, verb) = (.policy, .create)
    case "admission.policy.set-enabled": (resourceKind, verb) = (.policy, .update)
    case "admission.policy.delete", "admission.exception.delete":
      (resourceKind, verb) = (.policy, .delete)
    case "admission.exception.create": (resourceKind, verb) = (.policy, .approve)
    case "profile.list": (resourceKind, verb) = (.profile, .list)
    case "profile.get", "profile.resolve", "profile.preview", "profile.drift":
      (resourceKind, verb) = (.profile, .get)
    case "profile.create": (resourceKind, verb) = (.profile, .create)
    case "profile.update": (resourceKind, verb) = (.profile, .update)
    case "profile.delete": (resourceKind, verb) = (.profile, .delete)
    case "plugin.list": (resourceKind, verb) = (.plugin, .list)
    case "plugin.get", "plugin.status", "plugin.discover":
      (resourceKind, verb) = (.plugin, .get)
    case "plugin.install": (resourceKind, verb) = (.plugin, .create)
    case "plugin.update", "plugin.activate", "plugin.rollback", "plugin.quarantine":
      (resourceKind, verb) = (.plugin, .update)
    case "plugin.revoke": (resourceKind, verb) = (.plugin, .admin)
    case "plugin.uninstall": (resourceKind, verb) = (.plugin, .delete)
    default: (resourceKind, verb) = (.daemon, .admin)
    }
    if isSchedulerOperation {
      guard declaredMutation == nil else { throw RBACAuthorizationError.invalidTarget }
    }
    if declaredMutation == true {
      switch verb {
      case .get, .list, .watch, .plan:
        verb = .update
      case .create, .update, .delete, .start, .stop, .restart, .execute, .approve,
           .delegate, .admin:
        break
      }
    }
    return RBACAuthorizationTarget(
      resource: resourceKind, verb: verb, projectIdentifier: project,
      resourceIdentifier: resource, profileHash: profileHash)
  }

  private static func mappedVerb(_ value: String?, default fallback: RBACVerb) -> RBACVerb {
    let terminal = value?.split(separator: ".").last.map(String.init)
    switch terminal {
    case "list", "backups": return .list
    case "get", "inspect", "status", "verify", "validate", "preview", "providers",
         "query", "integrity", "snapshot": return .get
    case "create", "pull", "import", "install", "backup", "generate", "ingest",
         "discover", "fetch", "login", "bootstrap", "start", "kickstart": return .create
    case "update", "push", "tag", "repair", "restore", "recover", "compact",
         "retention", "resume", "release", "override", "handoff", "upgrade",
         "rollback", "stop", "cancel": return .update
    case "delete", "remove", "rm", "prune", "uninstall", "logout", "disable",
         "revoke-exception": return .delete
    case "approve": return .approve
    default: return fallback
    }
  }

  private struct LocalControlAuthorizationIntent {
    let verb: RBACVerb
  }

  private static func localControlAuthorizationIntent(
    operation: String,
    fields: [String: ControlPlaneJSONValue]
  ) throws -> LocalControlAuthorizationIntent? {
    switch operation {
    case "image":
      guard let selector = try string(in: fields, keys: ["imageOperation"]) else {
        return nil
      }
      let verb: RBACVerb
      switch selector {
      case "inspect", "cache-status": verb = .get
      case "pull": verb = .create
      case "push", "tag", "load", "save", "build", "pin", "unpin": verb = .update
      case "delete", "prune": verb = .delete
      default: throw RBACAuthorizationError.invalidTarget
      }
      return LocalControlAuthorizationIntent(verb: verb)
    case "volume":
      guard let selector = try string(in: fields, keys: ["volumeOperation"]) else {
        return nil
      }
      let verb: RBACVerb
      switch selector {
      case "list", "inspect", "capacity", "health", "snapshot-list",
           "snapshot-inspect", "backup-list", "backup-inspect", "backup-verify":
        verb = selector == "list" || selector.hasSuffix("-list") ? .list : .get
      case "snapshot-create", "backup-create": verb = .create
      case "recover", "snapshot-retain", "snapshot-export", "snapshot-restore",
           "backup-retain", "backup-restore":
        verb = .update
      case "delete", "prune", "snapshot-delete", "backup-delete": verb = .delete
      default: throw RBACAuthorizationError.invalidTarget
      }
      return LocalControlAuthorizationIntent(verb: verb)
    case "registry":
      let selectors = try [
        ("referrers", string(in: fields, keys: ["registryReferrerOperation"])),
        ("trust", string(in: fields, keys: ["registryTrustOperation"])),
        ("sbom", string(in: fields, keys: ["registrySBOMOperation"])),
        ("vulnerability", string(in: fields, keys: ["registryVulnerabilityOperation"])),
        ("provenance", string(in: fields, keys: ["registryProvenanceOperation"])),
      ].compactMap { namespace, selector in
        selector.map { (namespace, $0) }
      }
      guard selectors.count <= 1 else { throw RBACAuthorizationError.invalidTarget }
      guard let (namespace, selector) = selectors.first else { return nil }
      let verb: RBACVerb
      switch (namespace, selector) {
      case ("referrers", "status"), ("trust", "status"), ("sbom", "query"),
           ("vulnerability", "status"), ("provenance", "status"):
        verb = .get
      case ("referrers", "discover"), ("referrers", "fetch"),
           ("sbom", "generate"), ("sbom", "ingest"), ("provenance", "generate"):
        verb = .create
      case ("referrers", "prune"), ("trust", "revoke-exception"),
           ("vulnerability", "revoke-exception"):
        verb = .delete
      case ("referrers", "publish"), ("referrers", "copy"),
           ("referrers", "retain"), ("referrers", "release"),
           ("referrers", "resume"), ("trust", "verify"),
           ("trust", "grant-exception"), ("sbom", "export"),
           ("sbom", "resume"), ("vulnerability", "evaluate"),
           ("vulnerability", "grant-exception"), ("vulnerability", "resume"),
           ("provenance", "verify"), ("provenance", "resume"):
        verb = .update
      default: throw RBACAuthorizationError.invalidTarget
      }
      return LocalControlAuthorizationIntent(verb: verb)
    default:
      return nil
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

  private static func boolean(
    in fields: [String: ControlPlaneJSONValue], key: String
  ) throws -> Bool? {
    guard let field = fields[key] else { return nil }
    guard case .bool(let value) = field else {
      throw RBACAuthorizationError.invalidTarget
    }
    return value
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
