import Foundation
import HostwrightControlPlane

public struct RBACRepository: Sendable {
  private let store: SQLiteStateStore

  public init(store: SQLiteStateStore) {
    self.store = store
  }

  public func bootstrapDefaultRolesAndOwner(subjectID: String, timestamp: String) throws {
    try RBACStateValidation.identifier(subjectID, named: "bootstrap subject ID")
    _ = try RBACStateValidation.timestamp(timestamp, named: "bootstrap timestamp")
    try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(subjectID, on: connection)
        let defaults = try Self.defaultRoles(timestamp: timestamp)
        for expected in defaults {
          if let stored = try loadRole(expected.roleID, on: connection) {
            guard Self.matchesFrozenDefault(stored, expected) else {
              throw StateStoreError.transactionInvariantViolation(
                message: "Built-in role \(expected.roleID) differs from the frozen default policy."
              )
            }
          } else {
            try insertRole(expected, on: connection)
          }
        }
        let unknownBuiltIns = try connection.query(
          "SELECT role_id FROM rbac_roles WHERE built_in = 1 ORDER BY role_id"
        ).compactMap(\.first)
        guard unknownBuiltIns == DefaultRole.allCases.map(\.rawValue).sorted() else {
          throw StateStoreError.transactionInvariantViolation(
            message: "The persistent built-in role set differs from the frozen default policy."
          )
        }
        let owners = try globalOwnerBindings(on: connection)
        if owners.isEmpty {
          let activeSubjects = try connection.query(
            "SELECT subject_id, declared_by_subject_id FROM peer_identities WHERE revoked_at IS NULL ORDER BY subject_id"
          )
          guard activeSubjects.count == 1,
            activeSubjects[0].count == 2,
            activeSubjects[0][0] == subjectID,
            activeSubjects[0][1] == subjectID
          else {
            throw StateStoreError.transactionInvariantViolation(
              message: "Owner bootstrap requires exactly one active self-declared identity."
            )
          }
          try insertBinding(
            RBACBindingRecord(
              bindingID: "bootstrap-owner", subjectID: subjectID,
              roleID: DefaultRole.owner.rawValue, scope: RBACScope(kind: .global),
              createdBySubjectID: subjectID, createdAt: timestamp, updatedAt: timestamp
            ), on: connection
          )
        }
      }
    }
  }

  public func role(id: String) throws -> RBACRoleRecord? {
    try RBACStateValidation.identifier(id, named: "role ID")
    return try store.withValidatedConnection(readOnly: true) { try loadRole(id, on: $0) }
  }

  public func listRoles() throws -> [RBACRoleRecord] {
    try store.withValidatedConnection(readOnly: true) { connection in
      try connection.query(
        """
        SELECT role_id, built_in, rules_json, generation, created_by_subject_id, created_at, updated_at
        FROM rbac_roles ORDER BY role_id
        """
      ).map(role(from:))
    }
  }

  public func createCustomRole(
    _ role: RBACRoleRecord, actorSubjectID: String, timestamp: String
  ) throws -> RBACRoleRecord {
    try RBACStateValidation.identifier(actorSubjectID, named: "role actor subject ID")
    _ = try RBACStateValidation.timestamp(timestamp, named: "role creation timestamp")
    var normalized = try role.canonicalized()
    guard !normalized.builtIn, !DefaultRole.allCases.map(\.rawValue).contains(normalized.roleID) else {
      throw StateStoreError.invalidRecord("Custom roles cannot use built-in role identifiers.")
    }
    guard normalized.generation == 1 else {
      throw StateStoreError.invalidRecord("New custom roles must begin at generation one.")
    }
    normalized = RBACRoleRecord(
      roleID: normalized.roleID, builtIn: false, rules: normalized.rules, generation: 1,
      createdBySubjectID: actorSubjectID, createdAt: timestamp, updatedAt: timestamp
    )
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(actorSubjectID, on: connection)
        guard try loadRole(normalized.roleID, on: connection) == nil else {
          throw StateStoreError.invalidRecord("RBAC role ID is already in use.")
        }
        try insertRole(normalized, on: connection)
        return normalized
      }
    }
  }

  public func updateCustomRole(
    _ role: RBACRoleRecord, expectedGeneration: Int, actorSubjectID: String, timestamp: String
  ) throws -> RBACRoleRecord {
    try RBACStateValidation.identifier(actorSubjectID, named: "role actor subject ID")
    _ = try RBACStateValidation.timestamp(timestamp, named: "role update timestamp")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected role generation must be at least one.")
    }
    let normalized = try role.canonicalized()
    guard !normalized.builtIn, !DefaultRole.allCases.map(\.rawValue).contains(normalized.roleID) else {
      throw StateStoreError.invalidRecord("Built-in roles cannot be updated.")
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(actorSubjectID, on: connection)
        guard let existing = try loadRole(normalized.roleID, on: connection) else {
          throw StateStoreError.notFound("RBAC role \(normalized.roleID) does not exist.")
        }
        guard !existing.builtIn else {
          throw StateStoreError.invalidRecord("Built-in roles cannot be updated.")
        }
        guard existing.generation == expectedGeneration else {
          throw StateStoreError.transactionInvariantViolation(
            message: "RBAC role generation does not match the current record."
          )
        }
        let replacement = RBACRoleRecord(
          roleID: existing.roleID, builtIn: false, rules: normalized.rules,
          generation: existing.generation + 1, createdBySubjectID: existing.createdBySubjectID,
          createdAt: existing.createdAt, updatedAt: timestamp
        )
        try connection.run(
          """
          UPDATE rbac_roles SET rules_json = ?, generation = ?, updated_at = ?
          WHERE role_id = ? AND generation = ? AND built_in = 0
          """,
          bindings: [
            .text(try RBACStateValidation.canonicalJSON(replacement.rules)),
            .int(replacement.generation), .text(replacement.updatedAt), .text(replacement.roleID),
            .int(expectedGeneration),
          ]
        )
        guard let stored = try loadRole(replacement.roleID, on: connection), stored == replacement else {
          throw StateStoreError.transactionInvariantViolation(
            message: "RBAC role update did not persist the expected replacement."
          )
        }
        return stored
      }
    }
  }

  public func deleteCustomRole(id: String, expectedGeneration: Int) throws {
    try RBACStateValidation.identifier(id, named: "role ID")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected role generation must be at least one.")
    }
    try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try loadRole(id, on: connection) else {
          throw StateStoreError.notFound("RBAC role \(id) does not exist.")
        }
        guard !existing.builtIn else {
          throw StateStoreError.invalidRecord("Built-in roles cannot be deleted.")
        }
        guard existing.generation == expectedGeneration else {
          throw StateStoreError.transactionInvariantViolation(
            message: "RBAC role generation does not match the current record."
          )
        }
        let references = try connection.query(
          "SELECT COUNT(*) FROM rbac_bindings WHERE role_id = ?", bindings: [.text(id)]
        ).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
        guard references == 0 else {
          throw StateStoreError.invalidRecord("RBAC roles with bindings cannot be deleted.")
        }
        try connection.run(
          "DELETE FROM rbac_roles WHERE role_id = ? AND generation = ? AND built_in = 0",
          bindings: [.text(id), .int(expectedGeneration)]
        )
        guard try loadRole(id, on: connection) == nil else {
          throw StateStoreError.transactionInvariantViolation(
            message: "RBAC role deletion did not remove the expected record."
          )
        }
      }
    }
  }

  public func binding(id: String) throws -> RBACBindingRecord? {
    try RBACStateValidation.identifier(id, named: "binding ID")
    return try store.withValidatedConnection(readOnly: true) { try loadBinding(id, on: $0) }
  }

  public func listBindings(subjectID: String? = nil) throws -> [RBACBindingRecord] {
    if let subjectID { try RBACStateValidation.identifier(subjectID, named: "binding subject ID") }
    return try store.withValidatedConnection(readOnly: true) { connection in
      let rows: [[String?]]
      if let subjectID {
        rows = try connection.query(
          """
          SELECT binding_id, subject_id, role_id, scope_kind, scope_identifier,
                 created_by_subject_id, generation, created_at, updated_at
          FROM rbac_bindings WHERE subject_id = ? ORDER BY binding_id
          """, bindings: [.text(subjectID)]
        )
      } else {
        rows = try connection.query(
          """
          SELECT binding_id, subject_id, role_id, scope_kind, scope_identifier,
                 created_by_subject_id, generation, created_at, updated_at
          FROM rbac_bindings ORDER BY binding_id
          """
        )
      }
      return try rows.map(binding(from:))
    }
  }

  public func createBinding(_ binding: RBACBindingRecord) throws -> RBACBindingRecord {
    let normalized = try binding.canonicalized()
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(normalized.subjectID, on: connection)
        try requireActiveSubject(normalized.createdBySubjectID, on: connection)
        guard try loadRole(normalized.roleID, on: connection) != nil else {
          throw StateStoreError.notFound("RBAC binding role \(normalized.roleID) does not exist.")
        }
        guard try loadBinding(normalized.bindingID, on: connection) == nil else {
          throw StateStoreError.invalidRecord("RBAC binding ID is already in use.")
        }
        let duplicate = try bindingFor(
          subjectID: normalized.subjectID, roleID: normalized.roleID, scope: normalized.scope,
          on: connection
        )
        guard duplicate == nil else {
          throw StateStoreError.invalidRecord("An equivalent RBAC binding already exists.")
        }
        try insertBinding(normalized, on: connection)
        return normalized
      }
    }
  }

  public func deleteBinding(id: String, expectedGeneration: Int) throws {
    try RBACStateValidation.identifier(id, named: "binding ID")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected binding generation must be at least one.")
    }
    try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try loadBinding(id, on: connection) else {
          throw StateStoreError.notFound("RBAC binding \(id) does not exist.")
        }
        guard existing.generation == expectedGeneration else {
          throw StateStoreError.transactionInvariantViolation(
            message: "RBAC binding generation does not match the current record."
          )
        }
        if existing.roleID == DefaultRole.owner.rawValue, existing.scope.kind == .global {
          let activeOwners = try activeGlobalOwnerBindings(on: connection)
          if activeOwners.contains(where: { $0.bindingID == existing.bindingID }), activeOwners.count <= 1 {
            throw StateStoreError.invalidRecord("The last active global owner binding cannot be deleted.")
          }
        }
        try connection.run(
          "DELETE FROM rbac_bindings WHERE binding_id = ? AND generation = ?",
          bindings: [.text(id), .int(expectedGeneration)]
        )
        guard try loadBinding(id, on: connection) == nil else {
          throw StateStoreError.transactionInvariantViolation(
            message: "RBAC binding deletion did not remove the expected record."
          )
        }
      }
    }
  }

  public func delegation(id: String) throws -> RBACDelegationRecord? {
    try RBACStateValidation.identifier(id, named: "delegation ID")
    return try store.withValidatedConnection(readOnly: true) { try loadDelegation(id, on: $0) }
  }

  public func listDelegations(
    delegateSubjectID: String? = nil, activeAt: String? = nil
  ) throws -> [RBACDelegationRecord] {
    if let delegateSubjectID {
      try RBACStateValidation.identifier(delegateSubjectID, named: "delegate subject ID")
    }
    if let activeAt { _ = try RBACStateValidation.timestamp(activeAt, named: "delegation query timestamp") }
    return try store.withValidatedConnection(readOnly: true) { connection in
      var clauses: [String] = []
      var bindings: [SQLiteValue] = []
      if let delegateSubjectID {
        clauses.append("delegate_subject_id = ?")
        bindings.append(.text(delegateSubjectID))
      }
      if let activeAt {
        clauses.append("revoked_at IS NULL AND expires_at > ?")
        bindings.append(.text(activeAt))
      }
      let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
      return try connection.query(
        """
        SELECT delegation_id, delegator_subject_id, delegate_subject_id, role_ids_json,
               delegated_rules_json, scope_kind, scope_identifier, expires_at, revoked_at,
               generation, created_at, updated_at
        FROM rbac_delegations\(whereClause) ORDER BY delegation_id
        """, bindings: bindings
      ).map(delegation(from:))
    }
  }

  public func createDelegation(_ delegation: RBACDelegationRecord) throws -> RBACDelegationRecord {
    let normalized = try delegation.canonicalized()
    let created = try RBACStateValidation.timestamp(normalized.createdAt, named: "delegation creation timestamp")
    guard normalized.generation == 1 else {
      throw StateStoreError.invalidRecord("New delegations must begin at generation one.")
    }
    guard normalized.revokedAt == nil else {
      throw StateStoreError.invalidRecord("New delegations cannot be created revoked.")
    }
    guard try RBACStateValidation.timestamp(normalized.expiresAt, named: "delegation expiry timestamp") > created else {
      throw StateStoreError.invalidRecord("Delegation expiry must follow creation.")
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(normalized.delegatorSubjectID, on: connection)
        try requireActiveSubject(normalized.delegateSubjectID, on: connection)
        guard try loadDelegation(normalized.delegationID, on: connection) == nil else {
          throw StateStoreError.invalidRecord("RBAC delegation ID is already in use.")
        }
        for roleID in normalized.roleIDs {
          guard let role = try loadRole(roleID, on: connection) else {
            throw StateStoreError.notFound("Delegated RBAC role \(roleID) does not exist.")
          }
          guard role.roleID != DefaultRole.owner.rawValue else {
            throw StateStoreError.invalidRecord("Owner permissions cannot be delegated.")
          }
        }
        try insertDelegation(normalized, on: connection)
        return normalized
      }
    }
  }

  public func revokeDelegation(
    id: String, expectedGeneration: Int, revokedAt: String
  ) throws -> RBACDelegationRecord {
    try RBACStateValidation.identifier(id, named: "delegation ID")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected delegation generation must be at least one.")
    }
    let revoked = try RBACStateValidation.timestamp(revokedAt, named: "delegation revocation timestamp")
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try loadDelegation(id, on: connection) else {
          throw StateStoreError.notFound("RBAC delegation \(id) does not exist.")
        }
        guard existing.generation == expectedGeneration else {
          throw StateStoreError.transactionInvariantViolation(
            message: "RBAC delegation generation does not match the current record."
          )
        }
        guard existing.revokedAt == nil else {
          throw StateStoreError.invalidRecord("RBAC delegation is already revoked.")
        }
        guard revoked >= (try RBACStateValidation.timestamp(existing.createdAt, named: "delegation creation timestamp")) else {
          throw StateStoreError.invalidRecord("Delegation revocation predates creation.")
        }
        let replacement = RBACDelegationRecord(
          delegationID: existing.delegationID, delegatorSubjectID: existing.delegatorSubjectID,
          delegateSubjectID: existing.delegateSubjectID, roleIDs: existing.roleIDs,
          delegatedRules: existing.delegatedRules, scope: existing.scope,
          expiresAt: existing.expiresAt, revokedAt: revokedAt, generation: existing.generation + 1,
          createdAt: existing.createdAt, updatedAt: revokedAt
        )
        try connection.run(
          """
          UPDATE rbac_delegations SET revoked_at = ?, generation = ?, updated_at = ?
          WHERE delegation_id = ? AND generation = ? AND revoked_at IS NULL
          """,
          bindings: [.text(revokedAt), .int(replacement.generation), .text(revokedAt), .text(id), .int(expectedGeneration)]
        )
        guard let stored = try loadDelegation(id, on: connection), stored == replacement else {
          throw StateStoreError.transactionInvariantViolation(
            message: "RBAC delegation revocation did not persist the expected replacement."
          )
        }
        return stored
      }
    }
  }

  public static func defaultRoles(timestamp: String) throws -> [RBACRoleRecord] {
    try DefaultRole.allCases.map { role in
      let roleID = role.rawValue
      return try RBACRoleRecord(
        roleID: roleID, builtIn: true,
        rules: expandedDefaultRules(for: role), createdBySubjectID: nil,
        createdAt: timestamp, updatedAt: timestamp
      ).canonicalized()
    }.sorted { $0.roleID < $1.roleID }
  }

  private static func matchesFrozenDefault(_ stored: RBACRoleRecord, _ expected: RBACRoleRecord) -> Bool {
    stored.roleID == expected.roleID && stored.builtIn && stored.rules == expected.rules
      && stored.generation == 1 && stored.createdBySubjectID == nil
  }

  private static func expandedDefaultRules(for role: DefaultRole) -> [RBACRule] {
    let roles: [DefaultRole]
    switch role {
    case .viewer: roles = [.viewer]
    case .operator: roles = [.viewer, .operator]
    case .maintainer: roles = [.viewer, .operator, .maintainer]
    case .securityAdmin: roles = [.securityAdmin]
    case .owner: roles = [.owner]
    }
    return roles.compactMap { included in
      guard let permission = DefaultRolePolicy.matrix.first(where: { $0.role == included }) else {
        return nil
      }
      return RBACRule(
        identifier: "builtin.\(role.rawValue).\(included.rawValue).allow", effect: .allow,
        resources: permission.resources, verbs: permission.verbs, scope: RBACScope(kind: .global)
      )
    }
  }

  private func requireActiveSubject(_ subjectID: String, on connection: SQLiteConnection) throws {
    let rows = try connection.query(
      "SELECT subject_id FROM peer_identities WHERE subject_id = ? AND revoked_at IS NULL",
      bindings: [.text(subjectID)]
    )
    guard rows.count == 1 else {
      throw StateStoreError.notFound("RBAC subject \(subjectID) is not an active peer identity.")
    }
  }

  private func loadRole(_ id: String, on connection: SQLiteConnection) throws -> RBACRoleRecord? {
    let rows = try connection.query(
      """
      SELECT role_id, built_in, rules_json, generation, created_by_subject_id, created_at, updated_at
      FROM rbac_roles WHERE role_id = ?
      """, bindings: [.text(id)]
    )
    guard rows.count <= 1 else {
      throw StateStoreError.transactionInvariantViolation(message: "RBAC role primary key is not unique.")
    }
    return try rows.first.map(role(from:))
  }

  private func insertRole(_ role: RBACRoleRecord, on connection: SQLiteConnection) throws {
    try connection.run(
      """
      INSERT INTO rbac_roles (
          role_id, built_in, rules_json, generation, created_by_subject_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(role.roleID), .bool(role.builtIn), .text(try RBACStateValidation.canonicalJSON(role.rules)),
        .int(role.generation), optional(role.createdBySubjectID), .text(role.createdAt), .text(role.updatedAt),
      ]
    )
  }

  private func loadBinding(_ id: String, on connection: SQLiteConnection) throws -> RBACBindingRecord? {
    let rows = try connection.query(
      """
      SELECT binding_id, subject_id, role_id, scope_kind, scope_identifier,
             created_by_subject_id, generation, created_at, updated_at
      FROM rbac_bindings WHERE binding_id = ?
      """, bindings: [.text(id)]
    )
    guard rows.count <= 1 else {
      throw StateStoreError.transactionInvariantViolation(message: "RBAC binding primary key is not unique.")
    }
    return try rows.first.map(binding(from:))
  }

  private func bindingFor(
    subjectID: String, roleID: String, scope: RBACScope, on connection: SQLiteConnection
  ) throws -> RBACBindingRecord? {
    let rows = try connection.query(
      """
      SELECT binding_id, subject_id, role_id, scope_kind, scope_identifier,
             created_by_subject_id, generation, created_at, updated_at
      FROM rbac_bindings
      WHERE subject_id = ? AND role_id = ? AND scope_kind = ?
        AND ((scope_identifier IS NULL AND ? IS NULL) OR scope_identifier = ?)
      """,
      bindings: [.text(subjectID), .text(roleID), .text(scope.kind.rawValue), optional(scope.identifier), optional(scope.identifier)]
    )
    guard rows.count <= 1 else {
      throw StateStoreError.transactionInvariantViolation(message: "RBAC binding uniqueness is violated.")
    }
    return try rows.first.map(binding(from:))
  }

  private func insertBinding(_ binding: RBACBindingRecord, on connection: SQLiteConnection) throws {
    try connection.run(
      """
      INSERT INTO rbac_bindings (
          binding_id, subject_id, role_id, scope_kind, scope_identifier,
          created_by_subject_id, generation, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(binding.bindingID), .text(binding.subjectID), .text(binding.roleID),
        .text(binding.scope.kind.rawValue), optional(binding.scope.identifier),
        .text(binding.createdBySubjectID), .int(binding.generation), .text(binding.createdAt),
        .text(binding.updatedAt),
      ]
    )
  }

  private func globalOwnerBindings(on connection: SQLiteConnection) throws -> [RBACBindingRecord] {
    try connection.query(
      """
      SELECT binding_id, subject_id, role_id, scope_kind, scope_identifier,
             created_by_subject_id, generation, created_at, updated_at
      FROM rbac_bindings WHERE role_id = 'owner' AND scope_kind = 'global'
      ORDER BY binding_id
      """
    ).map(binding(from:))
  }

  private func activeGlobalOwnerBindings(on connection: SQLiteConnection) throws -> [RBACBindingRecord] {
    try connection.query(
      """
      SELECT b.binding_id, b.subject_id, b.role_id, b.scope_kind, b.scope_identifier,
             b.created_by_subject_id, b.generation, b.created_at, b.updated_at
      FROM rbac_bindings AS b
      JOIN peer_identities AS p ON p.subject_id = b.subject_id
      WHERE b.role_id = 'owner' AND b.scope_kind = 'global' AND p.revoked_at IS NULL
      ORDER BY b.binding_id
      """
    ).map(binding(from:))
  }

  private func loadDelegation(_ id: String, on connection: SQLiteConnection) throws -> RBACDelegationRecord? {
    let rows = try connection.query(
      """
      SELECT delegation_id, delegator_subject_id, delegate_subject_id, role_ids_json,
             delegated_rules_json, scope_kind, scope_identifier, expires_at, revoked_at,
             generation, created_at, updated_at
      FROM rbac_delegations WHERE delegation_id = ?
      """, bindings: [.text(id)]
    )
    guard rows.count <= 1 else {
      throw StateStoreError.transactionInvariantViolation(message: "RBAC delegation primary key is not unique.")
    }
    return try rows.first.map(delegation(from:))
  }

  private func insertDelegation(_ delegation: RBACDelegationRecord, on connection: SQLiteConnection) throws {
    try connection.run(
      """
      INSERT INTO rbac_delegations (
          delegation_id, delegator_subject_id, delegate_subject_id, role_ids_json,
          delegated_rules_json, scope_kind, scope_identifier, expires_at, revoked_at,
          generation, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(delegation.delegationID), .text(delegation.delegatorSubjectID),
        .text(delegation.delegateSubjectID), .text(try RBACStateValidation.canonicalJSON(delegation.roleIDs)),
        .text(try RBACStateValidation.canonicalJSON(delegation.delegatedRules)),
        .text(delegation.scope.kind.rawValue), optional(delegation.scope.identifier),
        .text(delegation.expiresAt), optional(delegation.revokedAt), .int(delegation.generation),
        .text(delegation.createdAt), .text(delegation.updatedAt),
      ]
    )
  }
}

private func role(from row: [String?]) throws -> RBACRoleRecord {
  guard row.count == 7, let roleID = row[0], let builtInText = row[1],
    let builtIn = ["0": false, "1": true][builtInText], let rulesJSON = row[2],
    let generationText = row[3], let generation = Int(generationText), let createdAt = row[5],
    let updatedAt = row[6]
  else { throw StateStoreError.invalidRecord("Stored RBAC role has an invalid shape.") }
  return try RBACRoleRecord(
    roleID: roleID, builtIn: builtIn, rules: RBACStateValidation.decodeRules(rulesJSON),
    generation: generation, createdBySubjectID: row[4], createdAt: createdAt, updatedAt: updatedAt
  ).canonicalized()
}

private func binding(from row: [String?]) throws -> RBACBindingRecord {
  guard row.count == 9, let bindingID = row[0], let subjectID = row[1], let roleID = row[2],
    let scopeText = row[3], let scopeKind = RBACScopeKind(rawValue: scopeText),
    let createdBySubjectID = row[5], let generationText = row[6], let generation = Int(generationText),
    let createdAt = row[7], let updatedAt = row[8]
  else { throw StateStoreError.invalidRecord("Stored RBAC binding has an invalid shape.") }
  return try RBACBindingRecord(
    bindingID: bindingID, subjectID: subjectID, roleID: roleID,
    scope: RBACScope(kind: scopeKind, identifier: row[4]), createdBySubjectID: createdBySubjectID,
    generation: generation, createdAt: createdAt, updatedAt: updatedAt
  ).canonicalized()
}

private func delegation(from row: [String?]) throws -> RBACDelegationRecord {
  guard row.count == 12, let delegationID = row[0], let delegator = row[1], let delegate = row[2],
    let roleIDsJSON = row[3], let rulesJSON = row[4], let scopeText = row[5],
    let scopeKind = RBACScopeKind(rawValue: scopeText), let expiresAt = row[7],
    let generationText = row[9], let generation = Int(generationText), let createdAt = row[10],
    let updatedAt = row[11]
  else { throw StateStoreError.invalidRecord("Stored RBAC delegation has an invalid shape.") }
  return try RBACDelegationRecord(
    delegationID: delegationID, delegatorSubjectID: delegator, delegateSubjectID: delegate,
    roleIDs: RBACStateValidation.decodeIdentifiers(roleIDsJSON),
    delegatedRules: RBACStateValidation.decodeRules(rulesJSON),
    scope: RBACScope(kind: scopeKind, identifier: row[6]), expiresAt: expiresAt, revokedAt: row[8],
    generation: generation, createdAt: createdAt, updatedAt: updatedAt
  ).canonicalized()
}

private func optional(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
