import CryptoKit
import Foundation
import HostwrightControlPlane

public struct WorkloadProfileRecord: Codable, Equatable, Sendable {
  public let profile: WorkloadProfile
  public let profileSHA256: String
  public let generation: Int
  public let createdBySubjectID: String
  public let createdAt: String
  public let updatedAt: String

  public init(
    profile: WorkloadProfile, profileSHA256: String? = nil, generation: Int = 1,
    createdBySubjectID: String, createdAt: String, updatedAt: String
  ) throws {
    try profile.validate()
    let digest = try Self.digest(profile)
    if let profileSHA256, profileSHA256 != digest {
      throw StateStoreError.invalidRecord("Workload profile digest does not match its canonical content.")
    }
    guard generation >= 1 else {
      throw StateStoreError.invalidRecord("Workload profile generation must be positive.")
    }
    try RBACStateValidation.identifier(createdBySubjectID, named: "profile creator")
    let created = try RBACStateValidation.timestamp(createdAt, named: "profile creation timestamp")
    let updated = try RBACStateValidation.timestamp(updatedAt, named: "profile update timestamp")
    guard updated >= created else {
      throw StateStoreError.invalidRecord("Workload profile update predates creation.")
    }
    self.profile = profile
    self.profileSHA256 = digest
    self.generation = generation
    self.createdBySubjectID = createdBySubjectID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static func digest(_ profile: WorkloadProfile) throws -> String {
    try profile.validate()
    return SHA256.hash(data: try ControlPlaneCanonicalJSON.encode(profile))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public struct WorkloadProfileRepository: Sendable {
  private let store: SQLiteStateStore

  public init(store: SQLiteStateStore) { self.store = store }

  public func profile(id: String) throws -> WorkloadProfileRecord? {
    try RBACStateValidation.identifier(id, named: "workload profile ID")
    return try store.withValidatedConnection(readOnly: true) { try load(id, on: $0) }
  }

  public func listProfiles() throws -> [WorkloadProfileRecord] {
    try store.withValidatedConnection(readOnly: true) { connection in
      try connection.query(
        """
        SELECT profile_id, version, parent_profile_id, profile_json, profile_sha256,
               generation, created_by_subject_id, created_at, updated_at
        FROM workload_profiles ORDER BY profile_id
        """).map(record(from:))
    }
  }

  public func create(_ record: WorkloadProfileRecord) throws -> WorkloadProfileRecord {
    guard record.generation == 1 else {
      throw StateStoreError.invalidRecord("New workload profiles must begin at generation one.")
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(record.createdBySubjectID, on: connection)
        guard try load(record.profile.identifier, on: connection) == nil else {
          throw StateStoreError.invalidRecord("Workload profile ID is already in use.")
        }
        if let parent = record.profile.parent {
          guard try load(parent, on: connection) != nil else {
            throw StateStoreError.notFound("Parent workload profile does not exist.")
          }
        }
        try insert(record, on: connection)
        try validateAcyclic(on: connection)
        guard let stored = try load(record.profile.identifier, on: connection), stored == record else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Workload profile creation did not persist exactly.")
        }
        return stored
      }
    }
  }

  public func update(
    profile: WorkloadProfile, expectedGeneration: Int, actorSubjectID: String, updatedAt: String
  ) throws -> WorkloadProfileRecord {
    try profile.validate()
    try RBACStateValidation.identifier(actorSubjectID, named: "profile actor")
    _ = try RBACStateValidation.timestamp(updatedAt, named: "profile update timestamp")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected workload profile generation must be positive.")
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(actorSubjectID, on: connection)
        guard let existing = try load(profile.identifier, on: connection) else {
          throw StateStoreError.notFound("Workload profile does not exist.")
        }
        guard existing.generation == expectedGeneration else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Workload profile generation does not match current state.")
        }
        if let parent = profile.parent {
          guard try load(parent, on: connection) != nil else {
            throw StateStoreError.notFound("Parent workload profile does not exist.")
          }
        }
        let updated = try WorkloadProfileRecord(
          profile: profile, generation: existing.generation + 1,
          createdBySubjectID: existing.createdBySubjectID,
          createdAt: existing.createdAt, updatedAt: updatedAt)
        try connection.run(
          """
          UPDATE workload_profiles
          SET version = ?, parent_profile_id = ?, profile_json = ?, profile_sha256 = ?,
              generation = ?, updated_at = ?
          WHERE profile_id = ? AND generation = ?
          """,
          bindings: [
            .int(profile.version), profile.parent.map(SQLiteValue.text) ?? .null,
            .text(String(decoding: try ControlPlaneCanonicalJSON.encode(profile), as: UTF8.self)),
            .text(updated.profileSHA256), .int(updated.generation), .text(updated.updatedAt),
            .text(profile.identifier), .int(expectedGeneration),
          ])
        try validateAcyclic(on: connection)
        guard let stored = try load(profile.identifier, on: connection), stored == updated else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Workload profile update did not persist exactly.")
        }
        return stored
      }
    }
  }

  public func delete(id: String, expectedGeneration: Int) throws {
    try RBACStateValidation.identifier(id, named: "workload profile ID")
    guard expectedGeneration >= 1 else {
      throw StateStoreError.invalidRecord("Expected workload profile generation must be positive.")
    }
    try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try load(id, on: connection), existing.generation == expectedGeneration else {
          throw StateStoreError.invalidRecord("Workload profile is missing or stale.")
        }
        let children = try count(
          "SELECT COUNT(*) FROM workload_profiles WHERE parent_profile_id = ?",
          bindings: [.text(id)], on: connection)
        guard children == 0 else {
          throw StateStoreError.invalidRecord("A workload profile with children cannot be deleted.")
        }
        try connection.run(
          "DELETE FROM workload_profiles WHERE profile_id = ? AND generation = ?",
          bindings: [.text(id), .int(expectedGeneration)])
        guard try load(id, on: connection) == nil else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Workload profile deletion did not remove the exact record.")
        }
      }
    }
  }

  private func insert(_ record: WorkloadProfileRecord, on connection: SQLiteConnection) throws {
    try connection.run(
      """
      INSERT INTO workload_profiles (
          profile_id, version, parent_profile_id, profile_json, profile_sha256,
          generation, created_by_subject_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(record.profile.identifier), .int(record.profile.version),
        record.profile.parent.map(SQLiteValue.text) ?? .null,
        .text(String(decoding: try ControlPlaneCanonicalJSON.encode(record.profile), as: UTF8.self)),
        .text(record.profileSHA256), .int(record.generation),
        .text(record.createdBySubjectID), .text(record.createdAt), .text(record.updatedAt),
      ])
  }

  private func load(_ id: String, on connection: SQLiteConnection) throws -> WorkloadProfileRecord? {
    let rows = try connection.query(
      """
      SELECT profile_id, version, parent_profile_id, profile_json, profile_sha256,
             generation, created_by_subject_id, created_at, updated_at
      FROM workload_profiles WHERE profile_id = ?
      """, bindings: [.text(id)])
    guard rows.count <= 1 else {
      throw StateStoreError.transactionInvariantViolation(
        message: "Workload profile primary key is not unique.")
    }
    return try rows.first.map(record(from:))
  }

  private func record(from row: [String?]) throws -> WorkloadProfileRecord {
    guard row.count == 9, let id = row[0], let version = row[1].flatMap(Int.init),
      let profileJSON = row[3], let profileData = profileJSON.data(using: .utf8),
      let profile = try? JSONDecoder().decode(WorkloadProfile.self, from: profileData),
      let digest = row[4], let generation = row[5].flatMap(Int.init), let creator = row[6],
      let createdAt = row[7], let updatedAt = row[8], profile.identifier == id,
      profile.version == version, profile.parent == row[2]
    else { throw StateStoreError.invalidRecord("Stored workload profile row is malformed.") }
    guard String(decoding: try ControlPlaneCanonicalJSON.encode(profile), as: UTF8.self) == profileJSON else {
      throw StateStoreError.invalidRecord("Stored workload profile JSON is not canonical.")
    }
    return try WorkloadProfileRecord(
      profile: profile, profileSHA256: digest, generation: generation,
      createdBySubjectID: creator, createdAt: createdAt, updatedAt: updatedAt)
  }

  private func validateAcyclic(on connection: SQLiteConnection) throws {
    let rows = try connection.query(
      "SELECT profile_id, parent_profile_id FROM workload_profiles ORDER BY profile_id")
    var identifiers = Set<String>()
    var parents: [String: String] = [:]
    for row in rows {
      guard row.count == 2, let identifier = row[0] else {
        throw StateStoreError.invalidRecord("Workload profile inheritance is malformed.")
      }
      guard identifiers.insert(identifier).inserted else {
        throw StateStoreError.invalidRecord("Workload profile inheritance has duplicate records.")
      }
      if let parent = row[1] { parents[identifier] = parent }
    }
    for identifier in parents.keys {
      var seen = Set<String>()
      var current: String? = identifier
      while let value = current {
        guard seen.insert(value).inserted else {
          throw StateStoreError.invalidRecord("Workload profile inheritance contains a cycle.")
        }
        guard seen.count <= 32 else {
          throw StateStoreError.invalidRecord("Workload profile inheritance exceeds 32 profiles.")
        }
        guard identifiers.contains(value) else {
          throw StateStoreError.invalidRecord("Workload profile inheritance has a missing record.")
        }
        current = parents[value]
      }
    }
  }

  private func count(
    _ sql: String, bindings: [SQLiteValue], on connection: SQLiteConnection
  ) throws -> Int {
    try connection.query(sql, bindings: bindings).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
  }

  private func requireActiveSubject(_ id: String, on connection: SQLiteConnection) throws {
    let active = try count(
      "SELECT COUNT(*) FROM peer_identities WHERE subject_id = ? AND revoked_at IS NULL",
      bindings: [.text(id)], on: connection)
    guard active == 1 else { throw StateStoreError.notFound("Workload profile subject is not active.") }
  }
}
