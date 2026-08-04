import CryptoKit
import Foundation
import HostwrightControlPlane

public enum PluginOwnedArtifactKind: String, Codable, Sendable {
  case file, directory
}

public struct PluginOwnedArtifact: Codable, Equatable, Sendable {
  public let path: String
  public let kind: PluginOwnedArtifactKind
  public let deviceID: UInt64
  public let inode: UInt64
  public let sha256Digest: String?

  public init(
    path: String, kind: PluginOwnedArtifactKind = .file, deviceID: UInt64, inode: UInt64,
    sha256Digest: String? = nil
  ) throws {
    guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/.."),
      deviceID > 0, inode > 0,
      (kind == .file && sha256Digest.map(PluginStateValidation.digest) == true
        || kind == .directory && sha256Digest == nil)
    else { throw StateStoreError.invalidRecord("Plugin-owned artifact identity is invalid.") }
    self.path = path
    self.kind = kind
    self.deviceID = deviceID
    self.inode = inode
    self.sha256Digest = sha256Digest
  }
}

public struct PluginPackageRecord: Codable, Equatable, Sendable {
  public let packageDigest: String
  public let manifest: PluginPackageManifest
  public let manifestDigest: String
  public let storagePath: String
  public let ownershipLedger: [PluginOwnedArtifact]
  public let lifecycleState: PluginLifecycleState
  public let generation: Int
  public let createdBySubjectID: String
  public let createdAt: String
  public let updatedAt: String

  public init(
    packageDigest: String, manifest: PluginPackageManifest, manifestDigest: String? = nil,
    storagePath: String, ownershipLedger: [PluginOwnedArtifact],
    lifecycleState: PluginLifecycleState, generation: Int = 1,
    createdBySubjectID: String, createdAt: String, updatedAt: String
  ) throws {
    try manifest.validate()
    guard PluginStateValidation.digest(packageDigest),
      packageDigest == manifest.provenance.checksum,
      manifest.signerIdentifier == manifest.provenance.signerIdentifier,
      storagePath.hasPrefix("/"), !storagePath.contains("/../"), !storagePath.hasSuffix("/.."),
      !ownershipLedger.isEmpty, generation >= 1
    else { throw StateStoreError.invalidRecord("Plugin package record is invalid.") }
    let canonicalDigest = try Self.digest(manifest)
    guard manifestDigest == nil || manifestDigest == canonicalDigest else {
      throw StateStoreError.invalidRecord("Plugin manifest digest does not match canonical content.")
    }
    let normalizedRoot = storagePath.hasSuffix("/") ? String(storagePath.dropLast()) : storagePath
    try ownershipLedger.forEach { artifact in
      _ = try PluginOwnedArtifact(
        path: artifact.path, kind: artifact.kind, deviceID: artifact.deviceID, inode: artifact.inode,
        sha256Digest: artifact.sha256Digest)
    }
    guard ownershipLedger.allSatisfy({ artifact in
      artifact.path == normalizedRoot || artifact.path.hasPrefix(normalizedRoot + "/")
    }), Set(ownershipLedger.map(\.path)).count == ownershipLedger.count else {
      throw StateStoreError.invalidRecord("Plugin ownership ledger escapes or duplicates its package root.")
    }
    try RBACStateValidation.identifier(createdBySubjectID, named: "plugin package creator")
    let created = try RBACStateValidation.timestamp(createdAt, named: "plugin package creation")
    let updated = try RBACStateValidation.timestamp(updatedAt, named: "plugin package update")
    guard updated >= created else {
      throw StateStoreError.invalidRecord("Plugin package update predates creation.")
    }
    self.packageDigest = packageDigest
    self.manifest = manifest
    self.manifestDigest = canonicalDigest
    self.storagePath = normalizedRoot
    self.ownershipLedger = ownershipLedger.sorted { $0.path < $1.path }
    self.lifecycleState = lifecycleState
    self.generation = generation
    self.createdBySubjectID = createdBySubjectID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static func digest(_ manifest: PluginPackageManifest) throws -> String {
    try manifest.validate()
    return PluginStateValidation.prefixedDigest(try ControlPlaneCanonicalJSON.encode(manifest))
  }
}

public struct PluginActivationRecord: Codable, Equatable, Sendable {
  public let pluginIdentifier: String
  public let activePackageDigest: String
  public let priorPackageDigest: String?
  public let healthStatus: String
  public let healthDetailDigest: String?
  public let generation: Int
  public let activatedBySubjectID: String
  public let activatedAt: String
  public let updatedAt: String
}

public struct PluginRollbackRecord: Codable, Equatable, Sendable {
  public let operationID: String
  public let pluginIdentifier: String
  public let fromPackageDigest: String?
  public let toPackageDigest: String
  public let stage: String
  public let status: String
  public let idempotencyKey: String
  public let ownershipEffects: [PluginOwnedArtifact]
  public let failureReasonCode: String?
  public let requestedBySubjectID: String
  public let generation: Int
  public let createdAt: String
  public let updatedAt: String

  public init(
    operationID: String, pluginIdentifier: String, fromPackageDigest: String?,
    toPackageDigest: String, stage: String, status: String, idempotencyKey: String,
    ownershipEffects: [PluginOwnedArtifact], failureReasonCode: String?,
    requestedBySubjectID: String, generation: Int, createdAt: String, updatedAt: String
  ) {
    self.operationID = operationID
    self.pluginIdentifier = pluginIdentifier
    self.fromPackageDigest = fromPackageDigest
    self.toPackageDigest = toPackageDigest
    self.stage = stage
    self.status = status
    self.idempotencyKey = idempotencyKey
    self.ownershipEffects = ownershipEffects
    self.failureReasonCode = failureReasonCode
    self.requestedBySubjectID = requestedBySubjectID
    self.generation = generation
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct PluginLifecycleRepository: Sendable {
  private let store: SQLiteStateStore

  public init(store: SQLiteStateStore) { self.store = store }

  public func package(digest: String) throws -> PluginPackageRecord? {
    try PluginStateValidation.requireDigest(digest, named: "plugin package digest")
    return try store.withValidatedConnection(readOnly: true) { try loadPackage(digest, on: $0) }
  }

  public func listPackages(identifier: String? = nil) throws -> [PluginPackageRecord] {
    if let identifier { try PluginStateValidation.identifier(identifier, named: "plugin identifier") }
    return try store.withValidatedConnection(readOnly: true) { connection in
      let filter = identifier == nil ? "" : " WHERE plugin_identifier = ?"
      let bindings = identifier.map { [SQLiteValue.text($0)] } ?? []
      return try connection.query(Self.packageSelect + filter + " ORDER BY plugin_identifier, package_version, package_digest", bindings: bindings)
        .map { try packageRecord(from: $0, on: connection) }
    }
  }

  public func persistVerifiedPackage(_ record: PluginPackageRecord) throws -> PluginPackageRecord {
    guard record.generation == 1,
      [.verified, .staged].contains(record.lifecycleState)
    else {
      throw StateStoreError.invalidRecord("A verified plugin package must begin in verified or staged state at generation one.")
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(record.createdBySubjectID, on: connection)
        guard try loadPackage(record.packageDigest, on: connection) == nil else {
          throw StateStoreError.invalidRecord("Plugin package digest is already installed.")
        }
        let manifestJSON = String(decoding: try ControlPlaneCanonicalJSON.encode(record.manifest), as: UTF8.self)
        let ownershipJSON = String(decoding: try ControlPlaneCanonicalJSON.encode(record.ownershipLedger), as: UTF8.self)
        try connection.run(
          """
          INSERT INTO plugin_packages (
            package_digest, plugin_identifier, package_version, hostwright_compatibility,
            provider_kind, entrypoint, artifact_digest, manifest_json, manifest_digest,
            cms_signature, signer_identifier, storage_path, ownership_ledger_json,
            lifecycle_state, generation, created_by_subject_id, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(record.packageDigest), .text(record.manifest.identifier),
            .text(record.manifest.packageVersion), .text(record.manifest.hostwrightCompatibility),
            .text(record.manifest.providerKind.rawValue), .text(record.manifest.entrypoint),
            .text(record.manifest.artifactDigest), .text(manifestJSON),
            .text(record.manifestDigest), .text(record.manifest.cmsSignature),
            .text(record.manifest.signerIdentifier), .text(record.storagePath),
            .text(ownershipJSON), .text(record.lifecycleState.rawValue), .int(record.generation),
            .text(record.createdBySubjectID), .text(record.createdAt), .text(record.updatedAt),
          ])
        let provenance = record.manifest.provenance
        try connection.run(
          """
          INSERT INTO plugin_provenance (
            package_digest, checksum, signature, signer_identifier, source_kind,
            source_locator, canonical_json, verified_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(record.packageDigest), .text(provenance.checksum), .text(provenance.signature),
            .text(provenance.signerIdentifier), .text(provenance.source.kind.rawValue),
            .text(provenance.source.locator),
            .text(String(decoding: try ControlPlaneCanonicalJSON.encode(provenance), as: UTF8.self)),
            .text(record.updatedAt),
          ])
        for grant in record.manifest.grants.sorted(by: Self.grantOrder) {
          try connection.run(
            """
            INSERT INTO plugin_grants (
              package_digest, capability, scope, approved_by_subject_id,
              approval_ref, granted_at, revoked_at
            ) VALUES (?, ?, ?, ?, ?, ?, NULL)
            """,
            bindings: [
              .text(record.packageDigest), .text(grant.capability.rawValue), .text(grant.scope),
              .text(record.createdBySubjectID), .text("plugin-package:" + record.manifestDigest),
              .text(record.updatedAt),
            ])
        }
        guard let stored = try loadPackage(record.packageDigest, on: connection), stored == record else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Verified plugin package did not persist exactly.")
        }
        return stored
      }
    }
  }

  public func transitionPackage(
    digest: String, to state: PluginLifecycleState, expectedGeneration: Int,
    actorSubjectID: String, updatedAt: String
  ) throws -> PluginPackageRecord {
    try PluginStateValidation.requireDigest(digest, named: "plugin package digest")
    try RBACStateValidation.identifier(actorSubjectID, named: "plugin lifecycle actor")
    _ = try RBACStateValidation.timestamp(updatedAt, named: "plugin lifecycle update")
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(actorSubjectID, on: connection)
        guard let existing = try loadPackage(digest, on: connection),
          existing.generation == expectedGeneration,
          Self.allowedTransitions[existing.lifecycleState]?.contains(state) == true
        else { throw StateStoreError.invalidRecord("Plugin lifecycle transition is missing, stale, or forbidden.") }
        let generation = existing.generation + 1
        try connection.run(
          "UPDATE plugin_packages SET lifecycle_state = ?, generation = ?, updated_at = ? WHERE package_digest = ? AND generation = ?",
          bindings: [.text(state.rawValue), .int(generation), .text(updatedAt), .text(digest), .int(expectedGeneration)])
        guard let stored = try loadPackage(digest, on: connection),
          stored.lifecycleState == state, stored.generation == generation
        else { throw StateStoreError.transactionInvariantViolation(message: "Plugin lifecycle transition did not persist exactly.") }
        return stored
      }
    }
  }

  public func activate(
    digest: String, expectedActivationGeneration: Int?, actorSubjectID: String,
    healthDetailDigest: String? = nil, timestamp: String
  ) throws -> PluginActivationRecord {
    try PluginStateValidation.requireDigest(digest, named: "active package digest")
    if let healthDetailDigest { try PluginStateValidation.requireDigest(healthDetailDigest, named: "plugin health detail digest") }
    try RBACStateValidation.identifier(actorSubjectID, named: "plugin activation actor")
    _ = try RBACStateValidation.timestamp(timestamp, named: "plugin activation timestamp")
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(actorSubjectID, on: connection)
        guard let package = try loadPackage(digest, on: connection),
          [.staged, .rollback].contains(package.lifecycleState),
          try !isRevoked(package, on: connection)
        else { throw StateStoreError.invalidRecord("Only a staged, non-revoked plugin package can activate.") }
        let existing = try loadActivation(package.manifest.identifier, on: connection)
        guard existing?.generation == expectedActivationGeneration else {
          throw StateStoreError.transactionInvariantViolation(message: "Plugin activation generation is stale.")
        }
        let generation = (existing?.generation ?? 0) + 1
        try connection.run(
          """
          INSERT INTO plugin_activations (
            plugin_identifier, active_package_digest, prior_package_digest, health_status,
            health_detail_digest, generation, activated_by_subject_id, activated_at, updated_at
          ) VALUES (?, ?, ?, 'healthy', ?, ?, ?, ?, ?)
          ON CONFLICT(plugin_identifier) DO UPDATE SET
            active_package_digest = excluded.active_package_digest,
            prior_package_digest = plugin_activations.active_package_digest,
            health_status = excluded.health_status,
            health_detail_digest = excluded.health_detail_digest,
            generation = excluded.generation,
            activated_by_subject_id = excluded.activated_by_subject_id,
            activated_at = excluded.activated_at,
            updated_at = excluded.updated_at
          """,
          bindings: [
            .text(package.manifest.identifier), .text(digest),
            existing.map { .text($0.activePackageDigest) } ?? .null,
            healthDetailDigest.map(SQLiteValue.text) ?? .null, .int(generation),
            .text(actorSubjectID), .text(timestamp), .text(timestamp),
          ])
        try connection.run(
          "UPDATE plugin_packages SET lifecycle_state = 'active', generation = generation + 1, updated_at = ? WHERE package_digest = ?",
          bindings: [.text(timestamp), .text(digest)])
        if let prior = existing?.activePackageDigest, prior != digest {
          try connection.run(
            "UPDATE plugin_packages SET lifecycle_state = 'rollback', generation = generation + 1, updated_at = ? WHERE package_digest = ? AND lifecycle_state = 'active'",
            bindings: [.text(timestamp), .text(prior)])
        }
        guard let stored = try loadActivation(package.manifest.identifier, on: connection),
          stored.activePackageDigest == digest, stored.generation == generation
        else { throw StateStoreError.transactionInvariantViolation(message: "Plugin activation did not persist atomically.") }
        return stored
      }
    }
  }

  public func activation(identifier: String) throws -> PluginActivationRecord? {
    try PluginStateValidation.identifier(identifier, named: "plugin identifier")
    return try store.withValidatedConnection(readOnly: true) { try loadActivation(identifier, on: $0) }
  }

  public func uninstall(
    digest: String, expectedGeneration: Int, actorSubjectID: String, timestamp: String
  ) throws -> PluginPackageRecord {
    try PluginStateValidation.requireDigest(digest, named: "uninstalled package digest")
    try RBACStateValidation.identifier(actorSubjectID, named: "plugin uninstall actor")
    _ = try RBACStateValidation.timestamp(timestamp, named: "plugin uninstall timestamp")
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(actorSubjectID, on: connection)
        guard let existing = try loadPackage(digest, on: connection) else {
          throw StateStoreError.invalidRecord("Plugin uninstall target is missing.")
        }
        if existing.lifecycleState == .uninstalled {
          guard expectedGeneration == existing.generation
            || expectedGeneration == existing.generation - 1
          else { throw StateStoreError.invalidRecord("Plugin uninstall target is stale.") }
          return existing
        }
        guard existing.generation == expectedGeneration else {
          throw StateStoreError.invalidRecord("Plugin uninstall target is stale.")
        }
        try connection.run(
          "DELETE FROM plugin_activations WHERE active_package_digest = ?",
          bindings: [.text(digest)])
        let generation = existing.generation + 1
        try connection.run(
          "UPDATE plugin_packages SET lifecycle_state = 'uninstalled', generation = ?, updated_at = ? WHERE package_digest = ? AND generation = ?",
          bindings: [.int(generation), .text(timestamp), .text(digest), .int(expectedGeneration)])
        guard let stored = try loadPackage(digest, on: connection),
          stored.lifecycleState == .uninstalled, stored.generation == generation
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Plugin uninstall state did not persist exactly.")
        }
        return stored
      }
    }
  }

  public func revoke(
    revocationID: String, targetKind: String, targetIdentifier: String, reason: String,
    actorSubjectID: String, timestamp: String
  ) throws {
    try RBACStateValidation.identifier(revocationID, named: "plugin revocation ID")
    guard ["package", "signer"].contains(targetKind), !targetIdentifier.isEmpty,
      targetIdentifier.utf8.count <= 256, !reason.isEmpty, reason.utf8.count <= 1024
    else { throw StateStoreError.invalidRecord("Plugin revocation is invalid.") }
    if targetKind == "package" { try PluginStateValidation.requireDigest(targetIdentifier, named: "revoked package digest") }
    try RBACStateValidation.identifier(actorSubjectID, named: "plugin revocation actor")
    _ = try RBACStateValidation.timestamp(timestamp, named: "plugin revocation timestamp")
    try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(actorSubjectID, on: connection)
        try connection.run(
          "INSERT INTO plugin_revocations (revocation_id, target_kind, target_identifier, reason, revoked_by_subject_id, revoked_at) VALUES (?, ?, ?, ?, ?, ?)",
          bindings: [.text(revocationID), .text(targetKind), .text(targetIdentifier), .text(reason), .text(actorSubjectID), .text(timestamp)])
        let predicate = targetKind == "package" ? "package_digest = ?" : "signer_identifier = ?"
        try connection.run(
          "UPDATE plugin_packages SET lifecycle_state = 'revoked', generation = generation + 1, updated_at = ? WHERE \(predicate) AND lifecycle_state != 'uninstalled'",
          bindings: [.text(timestamp), .text(targetIdentifier)])
        try connection.run(
          """
          UPDATE plugin_grants SET revoked_at = ? WHERE package_digest IN (
            SELECT package_digest FROM plugin_packages WHERE \(predicate)
          ) AND revoked_at IS NULL
          """, bindings: [.text(timestamp), .text(targetIdentifier)])
        try connection.run(
          """
          UPDATE plugin_activations SET health_status = 'revoked', generation = generation + 1,
            updated_at = ? WHERE active_package_digest IN (
              SELECT package_digest FROM plugin_packages WHERE \(predicate)
            )
          """, bindings: [.text(timestamp), .text(targetIdentifier)])
      }
    }
  }

  public func quarantine(
    quarantineID: String, packageDigest: String, reasonCode: String, detailDigest: String,
    actorSubjectID: String, timestamp: String
  ) throws {
    try RBACStateValidation.identifier(quarantineID, named: "plugin quarantine ID")
    try PluginStateValidation.requireDigest(packageDigest, named: "quarantined package digest")
    try PluginStateValidation.requireDigest(detailDigest, named: "quarantine detail digest")
    try RBACStateValidation.identifier(reasonCode, named: "quarantine reason code")
    try RBACStateValidation.identifier(actorSubjectID, named: "plugin quarantine actor")
    _ = try RBACStateValidation.timestamp(timestamp, named: "plugin quarantine timestamp")
    try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(actorSubjectID, on: connection)
        guard let package = try loadPackage(packageDigest, on: connection),
          package.lifecycleState != .uninstalled
        else { throw StateStoreError.notFound("Plugin package cannot be quarantined.") }
        try connection.run(
          "INSERT INTO plugin_quarantine (quarantine_id, package_digest, reason_code, detail_digest, quarantined_by_subject_id, quarantined_at, resolved_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
          bindings: [.text(quarantineID), .text(packageDigest), .text(reasonCode), .text(detailDigest), .text(actorSubjectID), .text(timestamp)])
        try connection.run(
          "UPDATE plugin_packages SET lifecycle_state = 'quarantined', generation = generation + 1, updated_at = ? WHERE package_digest = ?",
          bindings: [.text(timestamp), .text(packageDigest)])
        try connection.run(
          "UPDATE plugin_activations SET health_status = 'unhealthy', generation = generation + 1, updated_at = ? WHERE active_package_digest = ?",
          bindings: [.text(timestamp), .text(packageDigest)])
      }
    }
  }

  public func beginRollback(_ record: PluginRollbackRecord) throws -> PluginRollbackRecord {
    try validateRollback(record, requireInitial: true)
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        try requireActiveSubject(record.requestedBySubjectID, on: connection)
        try connection.run(
          """
          INSERT INTO plugin_rollback_state (
            operation_id, plugin_identifier, from_package_digest, to_package_digest,
            stage, status, idempotency_key, ownership_effects_json, failure_reason_code,
            requested_by_subject_id, generation, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(record.operationID), .text(record.pluginIdentifier),
            record.fromPackageDigest.map(SQLiteValue.text) ?? .null, .text(record.toPackageDigest),
            .text(record.stage), .text(record.status), .text(record.idempotencyKey),
            .text(String(decoding: try ControlPlaneCanonicalJSON.encode(record.ownershipEffects), as: UTF8.self)),
            record.failureReasonCode.map(SQLiteValue.text) ?? .null,
            .text(record.requestedBySubjectID), .int(record.generation),
            .text(record.createdAt), .text(record.updatedAt),
          ])
        guard let stored = try loadRollback(record.operationID, on: connection), stored == record else {
          throw StateStoreError.transactionInvariantViolation(message: "Plugin rollback intent did not persist exactly.")
        }
        return stored
      }
    }
  }

  public func rollback(operationID: String) throws -> PluginRollbackRecord? {
    try RBACStateValidation.identifier(operationID, named: "plugin rollback operation ID")
    return try store.withValidatedConnection(readOnly: true) { try loadRollback(operationID, on: $0) }
  }

  public func incompleteRollbackOperations() throws -> [PluginRollbackRecord] {
    try store.withValidatedConnection(readOnly: true) { connection in
      try connection.query(
        "SELECT operation_id FROM plugin_rollback_state WHERE status IN ('pending', 'running') ORDER BY created_at, operation_id"
      ).map { row in
        guard let operationID = row.first ?? nil,
          let operation = try loadRollback(operationID, on: connection)
        else { throw StateStoreError.invalidRecord("Stored plugin operation is missing.") }
        return operation
      }
    }
  }

  public func advanceRollback(
    operationID: String, expectedGeneration: Int, stage: String, status: String,
    ownershipEffects: [PluginOwnedArtifact]? = nil,
    failureReasonCode: String? = nil, updatedAt: String
  ) throws -> PluginRollbackRecord {
    try RBACStateValidation.identifier(operationID, named: "plugin rollback operation ID")
    _ = try RBACStateValidation.timestamp(updatedAt, named: "plugin rollback update")
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try loadRollback(operationID, on: connection),
          existing.generation == expectedGeneration,
          Self.rollbackTransitionAllowed(
            fromStage: existing.stage, fromStatus: existing.status,
            toStage: stage, toStatus: status)
        else { throw StateStoreError.invalidRecord("Plugin rollback transition is missing, stale, or forbidden.") }
        if let failureReasonCode {
          try RBACStateValidation.identifier(failureReasonCode, named: "plugin rollback failure reason")
        }
        guard (status == "failed") == (failureReasonCode != nil) else {
          throw StateStoreError.invalidRecord("Plugin rollback failure status and reason must agree.")
        }
        if let ownershipEffects {
          try ownershipEffects.forEach { artifact in
            _ = try PluginOwnedArtifact(
              path: artifact.path, kind: artifact.kind, deviceID: artifact.deviceID,
              inode: artifact.inode, sha256Digest: artifact.sha256Digest)
          }
        }
        let generation = existing.generation + 1
        try connection.run(
          "UPDATE plugin_rollback_state SET stage = ?, status = ?, ownership_effects_json = ?, failure_reason_code = ?, generation = ?, updated_at = ? WHERE operation_id = ? AND generation = ?",
          bindings: [
            .text(stage), .text(status),
            .text(String(decoding: try ControlPlaneCanonicalJSON.encode(ownershipEffects ?? existing.ownershipEffects), as: UTF8.self)),
            failureReasonCode.map(SQLiteValue.text) ?? .null,
            .int(generation), .text(updatedAt), .text(operationID), .int(expectedGeneration),
          ])
        guard let stored = try loadRollback(operationID, on: connection),
          stored.stage == stage, stored.status == status, stored.generation == generation
        else { throw StateStoreError.transactionInvariantViolation(message: "Plugin rollback transition did not persist exactly.") }
        return stored
      }
    }
  }

  func integrityProblems(on connection: SQLiteConnection) throws -> Int {
    var problems = 0
    for row in try connection.query(Self.packageSelect + " ORDER BY package_digest") {
      do { _ = try packageRecord(from: row, on: connection) } catch { problems += 1 }
    }
    for row in try connection.query(
      "SELECT plugin_identifier FROM plugin_activations ORDER BY plugin_identifier")
    {
      guard let identifier = row.first ?? nil else { problems += 1; continue }
      do { _ = try loadActivation(identifier, on: connection) } catch { problems += 1 }
    }
    for row in try connection.query(
      "SELECT operation_id FROM plugin_rollback_state ORDER BY operation_id")
    {
      guard let operationID = row.first ?? nil else { problems += 1; continue }
      do { _ = try loadRollback(operationID, on: connection) } catch { problems += 1 }
    }
    return problems
  }

  private func loadPackage(_ digest: String, on connection: SQLiteConnection) throws -> PluginPackageRecord? {
    let rows = try connection.query(Self.packageSelect + " WHERE package_digest = ?", bindings: [.text(digest)])
    guard rows.count <= 1 else { throw StateStoreError.transactionInvariantViolation(message: "Plugin package primary key is not unique.") }
    return try rows.first.map { try packageRecord(from: $0, on: connection) }
  }

  private func packageRecord(from row: [String?], on connection: SQLiteConnection) throws -> PluginPackageRecord {
    guard row.count == 18, let packageDigest = row[0], let identifier = row[1],
      let version = row[2], let compatibility = row[3], let kindRaw = row[4],
      let kind = PluginProviderKind(rawValue: kindRaw), let entrypoint = row[5],
      let artifactDigest = row[6], let manifestJSON = row[7],
      let manifestData = manifestJSON.data(using: .utf8),
      let manifest = try? JSONDecoder().decode(PluginPackageManifest.self, from: manifestData),
      let manifestDigest = row[8], let cms = row[9], let signer = row[10],
      let storagePath = row[11], let ownershipJSON = row[12],
      let ownershipData = ownershipJSON.data(using: .utf8),
      let ownership = try? JSONDecoder().decode([PluginOwnedArtifact].self, from: ownershipData),
      let stateRaw = row[13], let state = PluginLifecycleState(rawValue: stateRaw),
      let generation = row[14].flatMap(Int.init), let creator = row[15],
      let createdAt = row[16], let updatedAt = row[17],
      manifest.identifier == identifier, manifest.packageVersion == version,
      manifest.hostwrightCompatibility == compatibility, manifest.providerKind == kind,
      manifest.entrypoint == entrypoint, manifest.artifactDigest == artifactDigest,
      manifest.cmsSignature == cms, manifest.signerIdentifier == signer,
      String(decoding: try ControlPlaneCanonicalJSON.encode(manifest), as: UTF8.self) == manifestJSON,
      String(decoding: try ControlPlaneCanonicalJSON.encode(ownership.sorted { $0.path < $1.path }), as: UTF8.self) == ownershipJSON
    else { throw StateStoreError.invalidRecord("Stored plugin package row is malformed or noncanonical.") }
    let provenanceRows = try connection.query(
      "SELECT checksum, signature, signer_identifier, source_kind, source_locator, canonical_json FROM plugin_provenance WHERE package_digest = ?",
      bindings: [.text(packageDigest)])
    let expectedProvenance = manifest.provenance
    guard provenanceRows.count == 1, provenanceRows[0].count == 6,
      provenanceRows[0][0] == expectedProvenance.checksum,
      provenanceRows[0][1] == expectedProvenance.signature,
      provenanceRows[0][2] == expectedProvenance.signerIdentifier,
      provenanceRows[0][3] == expectedProvenance.source.kind.rawValue,
      provenanceRows[0][4] == expectedProvenance.source.locator,
      let provenanceJSON = provenanceRows[0][5],
      provenanceJSON == String(decoding: try ControlPlaneCanonicalJSON.encode(expectedProvenance), as: UTF8.self)
    else { throw StateStoreError.invalidRecord("Stored plugin provenance does not match its manifest.") }
    let storedGrants = try connection.query(
      "SELECT capability, scope FROM plugin_grants WHERE package_digest = ? ORDER BY capability, scope",
      bindings: [.text(packageDigest)]).compactMap { row -> PluginGrant? in
        guard row.count == 2, let capabilityRaw = row[0], let capability = PluginCapability(rawValue: capabilityRaw), let scope = row[1] else { return nil }
        return PluginGrant(capability: capability, scope: scope)
      }
    guard storedGrants == manifest.grants.sorted(by: Self.grantOrder) else {
      throw StateStoreError.invalidRecord("Stored plugin grants do not match its manifest.")
    }
    return try PluginPackageRecord(
      packageDigest: packageDigest, manifest: manifest, manifestDigest: manifestDigest,
      storagePath: storagePath, ownershipLedger: ownership, lifecycleState: state,
      generation: generation, createdBySubjectID: creator, createdAt: createdAt, updatedAt: updatedAt)
  }

  private func loadActivation(_ identifier: String, on connection: SQLiteConnection) throws -> PluginActivationRecord? {
    let rows = try connection.query(
      "SELECT plugin_identifier, active_package_digest, prior_package_digest, health_status, health_detail_digest, generation, activated_by_subject_id, activated_at, updated_at FROM plugin_activations WHERE plugin_identifier = ?",
      bindings: [.text(identifier)])
    guard rows.count <= 1 else { throw StateStoreError.transactionInvariantViolation(message: "Plugin activation primary key is not unique.") }
    return try rows.first.map { row in
      let priorMatchesIdentifier: Bool
      if let prior = row[2] {
        priorMatchesIdentifier = try connection.query(
          "SELECT plugin_identifier FROM plugin_packages WHERE package_digest = ?",
          bindings: [.text(prior)]).first?.first ?? nil == identifier
      } else {
        priorMatchesIdentifier = true
      }
      guard row.count == 9, let pluginIdentifier = row[0], let active = row[1],
        let health = row[3], ["pending", "healthy", "degraded", "unhealthy", "revoked"].contains(health),
        let generation = row[5].flatMap(Int.init), let actor = row[6],
        let activatedAt = row[7], let updatedAt = row[8],
        try connection.query(
          "SELECT plugin_identifier FROM plugin_packages WHERE package_digest = ?",
          bindings: [.text(active)]).first?.first ?? nil == pluginIdentifier,
        priorMatchesIdentifier
      else { throw StateStoreError.invalidRecord("Stored plugin activation is malformed.") }
      return PluginActivationRecord(
        pluginIdentifier: pluginIdentifier, activePackageDigest: active,
        priorPackageDigest: row[2], healthStatus: health, healthDetailDigest: row[4],
        generation: generation, activatedBySubjectID: actor,
        activatedAt: activatedAt, updatedAt: updatedAt)
    }
  }

  private func loadRollback(_ operationID: String, on connection: SQLiteConnection) throws -> PluginRollbackRecord? {
    let rows = try connection.query(
      "SELECT operation_id, plugin_identifier, from_package_digest, to_package_digest, stage, status, idempotency_key, ownership_effects_json, failure_reason_code, requested_by_subject_id, generation, created_at, updated_at FROM plugin_rollback_state WHERE operation_id = ?",
      bindings: [.text(operationID)])
    guard rows.count <= 1 else { throw StateStoreError.transactionInvariantViolation(message: "Plugin rollback primary key is not unique.") }
    return try rows.first.map { row in
      guard row.count == 13, let operationID = row[0], let identifier = row[1],
        let target = row[3], let stage = row[4], let status = row[5], let key = row[6],
        let effectsJSON = row[7], let effectsData = effectsJSON.data(using: .utf8),
        let effects = try? JSONDecoder().decode([PluginOwnedArtifact].self, from: effectsData),
        let actor = row[9], let generation = row[10].flatMap(Int.init),
        let createdAt = row[11], let updatedAt = row[12],
        effectsJSON == String(decoding: try ControlPlaneCanonicalJSON.encode(effects), as: UTF8.self)
      else { throw StateStoreError.invalidRecord("Stored plugin rollback is malformed or noncanonical.") }
      let record = PluginRollbackRecord(
        operationID: operationID, pluginIdentifier: identifier, fromPackageDigest: row[2],
        toPackageDigest: target, stage: stage, status: status, idempotencyKey: key,
        ownershipEffects: effects, failureReasonCode: row[8], requestedBySubjectID: actor,
        generation: generation, createdAt: createdAt, updatedAt: updatedAt)
      try validateRollback(record, requireInitial: false)
      return record
    }
  }

  private func validateRollback(_ record: PluginRollbackRecord, requireInitial: Bool) throws {
    try RBACStateValidation.identifier(record.operationID, named: "plugin rollback operation ID")
    try PluginStateValidation.identifier(record.pluginIdentifier, named: "plugin rollback identifier")
    if let source = record.fromPackageDigest { try PluginStateValidation.requireDigest(source, named: "rollback source digest") }
    try PluginStateValidation.requireDigest(record.toPackageDigest, named: "rollback target digest")
    guard ["intent", "install-intent", "rollback-intent", "uninstall-intent", "staged", "health-check", "activation", "cleanup", "recovery-success-audit", "recovery-failure-audit", "complete", "failed", "cancelled"].contains(record.stage),
      ["pending", "running", "succeeded", "failed", "cancelled"].contains(record.status),
      !record.idempotencyKey.isEmpty, record.idempotencyKey.utf8.count <= 256,
      record.generation >= 1,
      !requireInitial || (["intent", "install-intent", "rollback-intent", "uninstall-intent"].contains(record.stage)
        && record.status == "pending" && record.generation == 1)
    else { throw StateStoreError.invalidRecord("Plugin rollback state is invalid.") }
    try RBACStateValidation.identifier(record.requestedBySubjectID, named: "plugin rollback actor")
    let created = try RBACStateValidation.timestamp(record.createdAt, named: "plugin rollback creation")
    let updated = try RBACStateValidation.timestamp(record.updatedAt, named: "plugin rollback update")
    guard updated >= created else { throw StateStoreError.invalidRecord("Plugin rollback update predates creation.") }
    try record.ownershipEffects.forEach { artifact in
      _ = try PluginOwnedArtifact(
        path: artifact.path, kind: artifact.kind, deviceID: artifact.deviceID, inode: artifact.inode,
        sha256Digest: artifact.sha256Digest)
    }
  }

  private func isRevoked(_ package: PluginPackageRecord, on connection: SQLiteConnection) throws -> Bool {
    let count = try connection.query(
      "SELECT COUNT(*) FROM plugin_revocations WHERE (target_kind = 'package' AND target_identifier = ?) OR (target_kind = 'signer' AND target_identifier = ?)",
      bindings: [.text(package.packageDigest), .text(package.manifest.signerIdentifier)])
      .first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
    return count > 0
  }

  private func requireActiveSubject(_ id: String, on connection: SQLiteConnection) throws {
    let count = try connection.query(
      "SELECT COUNT(*) FROM peer_identities WHERE subject_id = ? AND revoked_at IS NULL",
      bindings: [.text(id)]).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
    guard count == 1 else { throw StateStoreError.notFound("Plugin lifecycle subject is not active.") }
  }

  private static func grantOrder(_ lhs: PluginGrant, _ rhs: PluginGrant) -> Bool {
    (lhs.capability.rawValue, lhs.scope) < (rhs.capability.rawValue, rhs.scope)
  }

  private static let allowedTransitions: [PluginLifecycleState: Set<PluginLifecycleState>] = [
    .verified: [.staged, .quarantined, .revoked],
    .staged: [.active, .quarantined, .revoked, .uninstalled],
    .active: [.rollback, .quarantined, .revoked],
    .rollback: [.active, .quarantined, .revoked, .uninstalled],
    .quarantined: [.verified, .revoked, .uninstalled],
    .revoked: [.quarantined, .uninstalled],
  ]

  private static func rollbackTransitionAllowed(
    fromStage: String, fromStatus: String, toStage: String, toStatus: String
  ) -> Bool {
    guard !["succeeded", "failed", "cancelled"].contains(fromStatus) else { return false }
    let stages = ["intent", "staged", "health-check", "activation", "cleanup", "recovery-success-audit", "recovery-failure-audit", "complete"]
    let normalizedFrom = ["install-intent", "rollback-intent", "uninstall-intent"].contains(fromStage)
      ? "intent" : fromStage
    let normalizedTo = ["install-intent", "rollback-intent", "uninstall-intent"].contains(toStage)
      ? "intent" : toStage
    guard let from = stages.firstIndex(of: normalizedFrom), let to = stages.firstIndex(of: normalizedTo),
      to >= from, ["pending", "running", "succeeded", "failed", "cancelled"].contains(toStatus)
    else { return false }
    if toStatus == "succeeded" { return toStage == "complete" }
    if ["failed", "cancelled"].contains(toStatus) { return true }
    return toStatus == "running" && toStage != "complete"
  }

  private static let packageSelect = """
    SELECT package_digest, plugin_identifier, package_version, hostwright_compatibility,
           provider_kind, entrypoint, artifact_digest, manifest_json, manifest_digest,
           cms_signature, signer_identifier, storage_path, ownership_ledger_json,
           lifecycle_state, generation, created_by_subject_id, created_at, updated_at
    FROM plugin_packages
    """
}

enum PluginStateValidation {
  static func digest(_ value: String) -> Bool {
    value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
  }

  static func requireDigest(_ value: String, named name: String) throws {
    guard digest(value) else { throw StateStoreError.invalidRecord("\(name) is invalid.") }
  }

  static func identifier(_ value: String, named name: String) throws {
    guard !value.isEmpty, value.utf8.count <= 128,
      value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    else { throw StateStoreError.invalidRecord("\(name) is invalid.") }
  }

  static func prefixedDigest(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
