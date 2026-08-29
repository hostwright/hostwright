import Foundation
import HostwrightControlPlane

public struct RBACRoleRecord: Codable, Equatable, Sendable {
  public let roleID: String
  public let builtIn: Bool
  public let rules: [RBACRule]
  public let generation: Int
  public let createdBySubjectID: String?
  public let createdAt: String
  public let updatedAt: String

  public init(
    roleID: String,
    builtIn: Bool,
    rules: [RBACRule],
    generation: Int = 1,
    createdBySubjectID: String? = nil,
    createdAt: String,
    updatedAt: String
  ) {
    self.roleID = roleID
    self.builtIn = builtIn
    self.rules = rules
    self.generation = generation
    self.createdBySubjectID = createdBySubjectID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var definition: RoleDefinition {
    RoleDefinition(identifier: roleID, builtIn: builtIn, rules: rules)
  }

  public func canonicalized() throws -> RBACRoleRecord {
    try RBACStateValidation.identifier(roleID, named: "role ID")
    guard generation >= 1 else {
      throw StateStoreError.invalidRecord("RBAC role generation must be at least one.")
    }
    if let createdBySubjectID {
      try RBACStateValidation.identifier(createdBySubjectID, named: "role creator subject ID")
    }
    _ = try RBACStateValidation.timestamp(createdAt, named: "role creation timestamp")
    let updated = try RBACStateValidation.timestamp(updatedAt, named: "role update timestamp")
    let created = try RBACStateValidation.timestamp(createdAt, named: "role creation timestamp")
    guard updated >= created else {
      throw StateStoreError.invalidRecord("RBAC role update timestamp predates creation.")
    }
    let rules = try RBACStateValidation.canonicalRules(rules)
    guard !(builtIn && !DefaultRole.allCases.map(\.rawValue).contains(roleID)) else {
      throw StateStoreError.invalidRecord("Only declared default roles may be built in.")
    }
    guard (builtIn && createdBySubjectID == nil) || (!builtIn && createdBySubjectID != nil) else {
      throw StateStoreError.invalidRecord("Built-in roles have no creator; custom roles require one.")
    }
    return RBACRoleRecord(
      roleID: roleID, builtIn: builtIn, rules: rules, generation: generation,
      createdBySubjectID: createdBySubjectID, createdAt: createdAt, updatedAt: updatedAt
    )
  }
}

public struct RBACBindingRecord: Codable, Equatable, Sendable {
  public let bindingID: String
  public let subjectID: String
  public let roleID: String
  public let scope: RBACScope
  public let createdBySubjectID: String
  public let generation: Int
  public let createdAt: String
  public let updatedAt: String

  public init(
    bindingID: String,
    subjectID: String,
    roleID: String,
    scope: RBACScope,
    createdBySubjectID: String,
    generation: Int = 1,
    createdAt: String,
    updatedAt: String
  ) {
    self.bindingID = bindingID
    self.subjectID = subjectID
    self.roleID = roleID
    self.scope = scope
    self.createdBySubjectID = createdBySubjectID
    self.generation = generation
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var binding: RBACBinding {
    RBACBinding(identifier: bindingID, subject: subjectID, roleIdentifier: roleID, scope: scope)
  }

  public func canonicalized() throws -> RBACBindingRecord {
    try RBACStateValidation.identifier(bindingID, named: "binding ID")
    try RBACStateValidation.identifier(subjectID, named: "binding subject ID")
    try RBACStateValidation.identifier(roleID, named: "binding role ID")
    try RBACStateValidation.identifier(createdBySubjectID, named: "binding creator subject ID")
    guard generation >= 1 else {
      throw StateStoreError.invalidRecord("RBAC binding generation must be at least one.")
    }
    let scope = try RBACStateValidation.canonicalScope(scope)
    let created = try RBACStateValidation.timestamp(createdAt, named: "binding creation timestamp")
    let updated = try RBACStateValidation.timestamp(updatedAt, named: "binding update timestamp")
    guard updated >= created else {
      throw StateStoreError.invalidRecord("RBAC binding update timestamp predates creation.")
    }
    return RBACBindingRecord(
      bindingID: bindingID, subjectID: subjectID, roleID: roleID, scope: scope,
      createdBySubjectID: createdBySubjectID, generation: generation, createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

public struct RBACDelegationRecord: Codable, Equatable, Sendable {
  public let delegationID: String
  public let delegatorSubjectID: String
  public let delegateSubjectID: String
  public let roleIDs: [String]
  public let delegatedRules: [RBACRule]
  public let scope: RBACScope
  public let expiresAt: String
  public let revokedAt: String?
  public let generation: Int
  public let createdAt: String
  public let updatedAt: String

  public init(
    delegationID: String,
    delegatorSubjectID: String,
    delegateSubjectID: String,
    roleIDs: [String],
    delegatedRules: [RBACRule],
    scope: RBACScope,
    expiresAt: String,
    revokedAt: String? = nil,
    generation: Int = 1,
    createdAt: String,
    updatedAt: String
  ) {
    self.delegationID = delegationID
    self.delegatorSubjectID = delegatorSubjectID
    self.delegateSubjectID = delegateSubjectID
    self.roleIDs = roleIDs
    self.delegatedRules = delegatedRules
    self.scope = scope
    self.expiresAt = expiresAt
    self.revokedAt = revokedAt
    self.generation = generation
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var delegation: RBACDelegation {
    RBACDelegation(
      identifier: delegationID, delegator: delegatorSubjectID, delegate: delegateSubjectID,
      roleIdentifiers: roleIDs, delegatedRules: delegatedRules, scope: scope,
      expiresAt: RBACStateValidation.date(expiresAt) ?? .distantPast
    )
  }

  public func canonicalized() throws -> RBACDelegationRecord {
    try RBACStateValidation.identifier(delegationID, named: "delegation ID")
    try RBACStateValidation.identifier(delegatorSubjectID, named: "delegator subject ID")
    try RBACStateValidation.identifier(delegateSubjectID, named: "delegate subject ID")
    guard delegatorSubjectID != delegateSubjectID else {
      throw StateStoreError.invalidRecord("RBAC delegations cannot target their delegator.")
    }
    guard generation >= 1 else {
      throw StateStoreError.invalidRecord("RBAC delegation generation must be at least one.")
    }
    let roleIDs = try RBACStateValidation.canonicalIdentifiers(roleIDs, named: "delegated role IDs")
    guard !roleIDs.contains(DefaultRole.owner.rawValue) else {
      throw StateStoreError.invalidRecord("Owner permissions cannot be delegated.")
    }
    let delegatedRules = try RBACStateValidation.canonicalRules(delegatedRules)
    guard !roleIDs.isEmpty || !delegatedRules.isEmpty else {
      throw StateStoreError.invalidRecord("RBAC delegations require a role or rule.")
    }
    let scope = try RBACStateValidation.canonicalScope(scope)
    let created = try RBACStateValidation.timestamp(createdAt, named: "delegation creation timestamp")
    let updated = try RBACStateValidation.timestamp(updatedAt, named: "delegation update timestamp")
    let expires = try RBACStateValidation.timestamp(expiresAt, named: "delegation expiry timestamp")
    guard expires > created else {
      throw StateStoreError.invalidRecord("RBAC delegation expiry must follow creation.")
    }
    guard updated >= created else {
      throw StateStoreError.invalidRecord("RBAC delegation update timestamp predates creation.")
    }
    if let revokedAt {
      let revoked = try RBACStateValidation.timestamp(revokedAt, named: "delegation revocation timestamp")
      guard revoked >= created else {
        throw StateStoreError.invalidRecord("RBAC delegation revocation predates creation.")
      }
    }
    return RBACDelegationRecord(
      delegationID: delegationID, delegatorSubjectID: delegatorSubjectID,
      delegateSubjectID: delegateSubjectID, roleIDs: roleIDs, delegatedRules: delegatedRules,
      scope: scope, expiresAt: expiresAt, revokedAt: revokedAt, generation: generation,
      createdAt: createdAt, updatedAt: updatedAt
    )
  }
}

enum RBACStateValidation {
  static func identifier(_ value: String, named: String) throws {
    guard (1...128).contains(value.utf8.count),
      value.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) })
    else { throw StateStoreError.invalidRecord("\(named) is not a bounded printable ASCII identifier.") }
  }

  static func timestamp(_ value: String, named: String) throws -> Date {
    try ControlIdentityValidation.utcTimestamp(value, named: named)
  }

  static func date(_ value: String) -> Date? {
    ISO8601DateFormatter().date(from: value)
  }

  static func canonicalScope(_ scope: RBACScope) throws -> RBACScope {
    try scope.validate()
    if let identifier = scope.identifier {
      try self.identifier(identifier, named: "scope identifier")
    }
    return scope
  }

  static func canonicalIdentifiers(_ values: [String], named: String) throws -> [String] {
    try values.forEach { try identifier($0, named: named) }
    let canonical = Array(Set(values)).sorted()
    guard canonical.count == values.count else {
      throw StateStoreError.invalidRecord("\(named) must not contain duplicates.")
    }
    return canonical
  }

  static func canonicalRules(_ values: [RBACRule]) throws -> [RBACRule] {
    var normalized: [RBACRule] = []
    var encodings = Set<String>()
    var identifiers = Set<String>()
    for rule in values {
      try identifier(rule.identifier, named: "RBAC rule ID")
      try rule.validate()
      let resources = Array(Set(rule.resources)).sorted { $0.rawValue < $1.rawValue }
      let verbs = Array(Set(rule.verbs)).sorted { $0.rawValue < $1.rawValue }
      guard resources.count == rule.resources.count, verbs.count == rule.verbs.count else {
        throw StateStoreError.invalidRecord("RBAC rule resources and verbs must be deduplicated.")
      }
      let conditions = rule.conditions.sorted {
        ($0.kind.rawValue, $0.value) < ($1.kind.rawValue, $1.value)
      }
      guard Set(conditions.map { "\($0.kind.rawValue)\u{0}\($0.value)" }).count == conditions.count else {
        throw StateStoreError.invalidRecord("RBAC rule conditions must be deduplicated.")
      }
      for condition in conditions {
        try identifier(condition.value, named: "RBAC condition value")
        if condition.kind == .expiresAt {
          _ = try timestamp(condition.value, named: "RBAC condition expiry")
        }
      }
      let canonical = RBACRule(
        identifier: rule.identifier, effect: rule.effect, resources: resources, verbs: verbs,
        scope: try canonicalScope(rule.scope), conditions: conditions
      )
      let encoding = try canonicalJSON([canonical])
      guard identifiers.insert(canonical.identifier).inserted, encodings.insert(encoding).inserted else {
        throw StateStoreError.invalidRecord("RBAC rules must have unique identifiers and content.")
      }
      normalized.append(canonical)
    }
    return try normalized.sorted { try canonicalJSON([$0]) < canonicalJSON([$1]) }
  }

  static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let output = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw StateStoreError.invalidRecord("RBAC JSON cannot be encoded as UTF-8.")
    }
    return output
  }

  static func decodeRules(_ json: String) throws -> [RBACRule] {
    guard json.utf8.count <= 262_144,
      let data = json.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([RBACRule].self, from: data)
    else { throw StateStoreError.invalidRecord("Stored RBAC rules JSON is invalid or oversized.") }
    let canonical = try canonicalRules(decoded)
    guard try canonicalJSON(canonical) == json else {
      throw StateStoreError.invalidRecord("Stored RBAC rules JSON is not canonical.")
    }
    return canonical
  }

  static func decodeIdentifiers(_ json: String) throws -> [String] {
    guard json.utf8.count <= 262_144,
      let data = json.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String].self, from: data)
    else { throw StateStoreError.invalidRecord("Stored delegated role JSON is invalid or oversized.") }
    let canonical = try canonicalIdentifiers(decoded, named: "delegated role IDs")
    guard try canonicalJSON(canonical) == json else {
      throw StateStoreError.invalidRecord("Stored delegated role JSON is not canonical.")
    }
    return canonical
  }
}
