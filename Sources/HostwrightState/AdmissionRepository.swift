import Foundation
import HostwrightControlPlane

public struct AdmissionRepository: Sendable {
  private let store: SQLiteStateStore

  public init(store: SQLiteStateStore) {
    self.store = store
  }

  public func policy(id: String) throws -> AdmissionPolicyRecord? {
    try RBACStateValidation.identifier(id, named: "admission policy ID")
    return try store.withValidatedConnection(readOnly: true) { try loadPolicy(id, on: $0) }
  }

  public func listPolicies(enabledOnly: Bool = false) throws -> [AdmissionPolicyRecord] {
    try store.withValidatedConnection(readOnly: true) { connection in
      let suffix = enabledOnly ? " WHERE enabled = 1" : ""
      return try connection.query(
        """
        SELECT policy_id, version, source_kind, stage, failure_policy, advisory, mutating,
               document_json, document_sha256, enabled, generation,
               created_by_subject_id, created_at, updated_at
        FROM admission_policies\(suffix)
        ORDER BY CASE source_kind WHEN 'built-in' THEN 0 ELSE 1 END,
                 CASE stage
                   WHEN 'builtInMutation' THEN 0 WHEN 'extensionMutation' THEN 1
                   WHEN 'builtInValidation' THEN 2 ELSE 3 END,
                 policy_id, version
        """
      ).map(policy(from:))
    }
  }

  public func createPolicy(_ policy: AdmissionPolicyRecord) throws -> AdmissionPolicyRecord {
    let normalized = try policy.canonicalized()
    guard normalized.generation == 1 else {
      throw StateStoreError.invalidRecord("New admission policies must begin at generation one.")
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(normalized.createdBySubjectID, on: connection)
        guard try loadPolicy(normalized.policyID, on: connection) == nil else {
          throw StateStoreError.invalidRecord("Admission policy ID is already in use.")
        }
        try connection.run(
          """
          INSERT INTO admission_policies (
              policy_id, version, source_kind, stage, failure_policy, advisory, mutating,
              document_json, document_sha256, enabled, generation,
              created_by_subject_id, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(normalized.policyID), .int(normalized.version),
            .text(normalized.sourceKind.rawValue), .text(normalized.stage.rawValue),
            .text(normalized.failurePolicy.rawValue), .bool(normalized.advisory),
            .bool(normalized.mutating),
            .text(String(decoding: try ControlPlaneCanonicalJSON.encode(normalized.document), as: UTF8.self)),
            .text(normalized.documentSHA256), .bool(normalized.enabled),
            .int(normalized.generation), .text(normalized.createdBySubjectID),
            .text(normalized.createdAt), .text(normalized.updatedAt),
          ]
        )
        guard let stored = try loadPolicy(normalized.policyID, on: connection),
          stored == normalized
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Admission policy creation did not persist the expected record.")
        }
        return stored
      }
    }
  }

  public func setPolicyEnabled(
    id: String, enabled: Bool, expectedGeneration: Int, actorSubjectID: String,
    updatedAt: String
  ) throws -> AdmissionPolicyRecord {
    try RBACStateValidation.identifier(id, named: "admission policy ID")
    try RBACStateValidation.identifier(actorSubjectID, named: "admission policy actor")
    _ = try RBACStateValidation.timestamp(updatedAt, named: "admission policy update timestamp")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected admission policy generation must be positive.")
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(actorSubjectID, on: connection)
        guard let existing = try loadPolicy(id, on: connection) else {
          throw StateStoreError.notFound("Admission policy \(id) does not exist.")
        }
        guard existing.sourceKind != .builtIn else {
          throw StateStoreError.invalidRecord("Built-in admission policies are immutable.")
        }
        guard existing.generation == expectedGeneration else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Admission policy generation does not match current state.")
        }
        let generation = existing.generation + 1
        try connection.run(
          """
          UPDATE admission_policies SET enabled = ?, generation = ?, updated_at = ?
          WHERE policy_id = ? AND generation = ? AND source_kind = 'extension'
          """,
          bindings: [
            .bool(enabled), .int(generation), .text(updatedAt), .text(id),
            .int(expectedGeneration),
          ]
        )
        guard let stored = try loadPolicy(id, on: connection),
          stored.enabled == enabled, stored.generation == generation
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Admission policy enablement did not persist exactly.")
        }
        return stored
      }
    }
  }

  public func deletePolicy(id: String, expectedGeneration: Int) throws {
    try RBACStateValidation.identifier(id, named: "admission policy ID")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected admission policy generation must be positive.")
    }
    try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try loadPolicy(id, on: connection) else {
          throw StateStoreError.notFound("Admission policy \(id) does not exist.")
        }
        guard existing.sourceKind != .builtIn, existing.generation == expectedGeneration else {
          throw StateStoreError.invalidRecord(
            "Built-in or stale admission policy cannot be deleted.")
        }
        let references = try connection.query(
          "SELECT COUNT(*) FROM admission_exceptions WHERE policy_id = ?",
          bindings: [.text(id)]
        ).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
        guard references == 0 else {
          throw StateStoreError.invalidRecord(
            "Admission policy with exception history cannot be deleted; disable it instead.")
        }
        try connection.run(
          "DELETE FROM admission_policies WHERE policy_id = ? AND generation = ?",
          bindings: [.text(id), .int(expectedGeneration)]
        )
        guard try loadPolicy(id, on: connection) == nil else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Admission policy deletion did not remove the exact record.")
        }
      }
    }
  }

  public func exception(id: String) throws -> AdmissionExceptionRecord? {
    try RBACStateValidation.identifier(id, named: "admission exception ID")
    return try store.withValidatedConnection(readOnly: true) { try loadException(id, on: $0) }
  }

  public func listExceptions(
    policyID: String? = nil, subjectID: String? = nil, activeAt: String? = nil
  ) throws -> [AdmissionExceptionRecord] {
    if let policyID { try RBACStateValidation.identifier(policyID, named: "exception policy ID") }
    if let subjectID { try RBACStateValidation.identifier(subjectID, named: "exception subject ID") }
    if let activeAt { _ = try RBACStateValidation.timestamp(activeAt, named: "exception query time") }
    return try store.withValidatedConnection(readOnly: true) { connection in
      var clauses: [String] = []
      var bindings: [SQLiteValue] = []
      if let policyID { clauses.append("policy_id = ?"); bindings.append(.text(policyID)) }
      if let subjectID { clauses.append("subject_id = ?"); bindings.append(.text(subjectID)) }
      if let activeAt {
        clauses.append("julianday(expires_at) > julianday(?)")
        bindings.append(.text(activeAt))
      }
      let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
      return try connection.query(
        """
        SELECT exception_id, policy_id, subject_id, target, plan_hash, approval_identity,
               expires_at, created_by_subject_id, generation, created_at, updated_at
        FROM admission_exceptions\(filter) ORDER BY exception_id
        """, bindings: bindings
      ).map(exception(from:))
    }
  }

  public func createException(
    _ exception: AdmissionExceptionRecord
  ) throws -> AdmissionExceptionRecord {
    let normalized = try exception.canonicalized()
    guard normalized.generation == 1 else {
      throw StateStoreError.invalidRecord("New admission exceptions must begin at generation one.")
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(normalized.subjectID, on: connection)
        try requireActiveSubject(normalized.createdBySubjectID, on: connection)
        guard let policy = try loadPolicy(normalized.policyID, on: connection), policy.enabled else {
          throw StateStoreError.notFound("Admission exception policy is missing or disabled.")
        }
        guard try loadException(normalized.exceptionID, on: connection) == nil else {
          throw StateStoreError.invalidRecord("Admission exception ID is already in use.")
        }
        try connection.run(
          """
          INSERT INTO admission_exceptions (
              exception_id, policy_id, subject_id, target, plan_hash, approval_identity,
              expires_at, created_by_subject_id, generation, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(normalized.exceptionID), .text(normalized.policyID),
            .text(normalized.subjectID), .text(normalized.target), .text(normalized.planHash),
            .text(normalized.approvalIdentity), .text(normalized.expiresAt),
            .text(normalized.createdBySubjectID), .int(normalized.generation),
            .text(normalized.createdAt), .text(normalized.updatedAt),
          ]
        )
        guard let stored = try loadException(normalized.exceptionID, on: connection),
          stored == normalized
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Admission exception creation did not persist exactly.")
        }
        return stored
      }
    }
  }

  public func deleteException(id: String, expectedGeneration: Int) throws {
    try RBACStateValidation.identifier(id, named: "admission exception ID")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected admission exception generation must be positive.")
    }
    try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try loadException(id, on: connection),
          existing.generation == expectedGeneration
        else { throw StateStoreError.invalidRecord("Admission exception is missing or stale.") }
        try connection.run(
          "DELETE FROM admission_exceptions WHERE exception_id = ? AND generation = ?",
          bindings: [.text(id), .int(expectedGeneration)]
        )
        guard try loadException(id, on: connection) == nil else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Admission exception deletion did not remove the exact record.")
        }
      }
    }
  }

  private func requireActiveSubject(_ id: String, on connection: SQLiteConnection) throws {
    let count = try connection.query(
      "SELECT COUNT(*) FROM peer_identities WHERE subject_id = ? AND revoked_at IS NULL",
      bindings: [.text(id)]
    ).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
    guard count == 1 else { throw StateStoreError.notFound("Admission subject is not active.") }
  }

  private func loadPolicy(
    _ id: String, on connection: SQLiteConnection
  ) throws -> AdmissionPolicyRecord? {
    let rows = try connection.query(
      """
      SELECT policy_id, version, source_kind, stage, failure_policy, advisory, mutating,
             document_json, document_sha256, enabled, generation,
             created_by_subject_id, created_at, updated_at
      FROM admission_policies WHERE policy_id = ?
      """, bindings: [.text(id)]
    )
    guard rows.count <= 1 else {
      throw StateStoreError.transactionInvariantViolation(
        message: "Admission policy primary key is not unique.")
    }
    return try rows.first.map(policy(from:))
  }

  private func loadException(
    _ id: String, on connection: SQLiteConnection
  ) throws -> AdmissionExceptionRecord? {
    let rows = try connection.query(
      """
      SELECT exception_id, policy_id, subject_id, target, plan_hash, approval_identity,
             expires_at, created_by_subject_id, generation, created_at, updated_at
      FROM admission_exceptions WHERE exception_id = ?
      """, bindings: [.text(id)]
    )
    guard rows.count <= 1 else {
      throw StateStoreError.transactionInvariantViolation(
        message: "Admission exception primary key is not unique.")
    }
    return try rows.first.map(exception(from:))
  }

  private func policy(from row: [String?]) throws -> AdmissionPolicyRecord {
    guard row.count == 14, let policyID = row[0], let version = row[1].flatMap(Int.init),
      let sourceRaw = row[2], let source = AdmissionPolicySourceKind(rawValue: sourceRaw),
      let stageRaw = row[3], let stage = AdmissionStage(rawValue: stageRaw),
      let failureRaw = row[4], let failure = AdmissionFailurePolicy(rawValue: failureRaw),
      let advisory = row[5].flatMap(Int.init), let mutating = row[6].flatMap(Int.init),
      let documentJSON = row[7], let documentData = documentJSON.data(using: .utf8),
      let document = try? JSONDecoder().decode(ControlPlaneJSONValue.self, from: documentData),
      let documentSHA = row[8], let enabled = row[9].flatMap(Int.init),
      let generation = row[10].flatMap(Int.init), let creator = row[11],
      let createdAt = row[12], let updatedAt = row[13],
      (advisory == 0 || advisory == 1), (mutating == 0 || mutating == 1),
      (enabled == 0 || enabled == 1)
    else { throw StateStoreError.invalidRecord("Stored admission policy row is malformed.") }
    let record = AdmissionPolicyRecord(
      policyID: policyID, version: version, sourceKind: source, stage: stage,
      failurePolicy: failure, advisory: advisory == 1, mutating: mutating == 1,
      document: document, documentSHA256: documentSHA, enabled: enabled == 1,
      generation: generation, createdBySubjectID: creator,
      createdAt: createdAt, updatedAt: updatedAt)
    let normalized = try record.canonicalized()
    guard String(decoding: try ControlPlaneCanonicalJSON.encode(document), as: UTF8.self)
      == documentJSON
    else { throw StateStoreError.invalidRecord("Stored admission policy JSON is not canonical.") }
    return normalized
  }

  private func exception(from row: [String?]) throws -> AdmissionExceptionRecord {
    guard row.count == 11, let id = row[0], let policyID = row[1], let subjectID = row[2],
      let target = row[3], let planHash = row[4], let approval = row[5],
      let expiresAt = row[6], let creator = row[7], let generation = row[8].flatMap(Int.init),
      let createdAt = row[9], let updatedAt = row[10]
    else { throw StateStoreError.invalidRecord("Stored admission exception row is malformed.") }
    return try AdmissionExceptionRecord(
      exceptionID: id, policyID: policyID, subjectID: subjectID, target: target,
      planHash: planHash, approvalIdentity: approval, expiresAt: expiresAt,
      createdBySubjectID: creator, generation: generation,
      createdAt: createdAt, updatedAt: updatedAt).canonicalized()
  }
}
