import CryptoKit
import Foundation
import HostwrightControlPlane

public enum AuditTrailError: Error, Equatable, Sendable {
  case invalidInput(String)
  case chainCorrupt(String)
  case signingFailed
  case anchorMismatch
  case clockRegression
  case retentionRejected
  case keyRotationFailed
}

extension AuditTrailError: StateTransactionPreservedError {}

public struct AuditAppendInput: Equatable, Sendable {
  public let subjectID: String
  public let requestID: String?
  public let target: String?
  public let action: AuditAction
  public let outcome: String
  public let reasonCode: String
  public let policyRef: String?
  public let planRef: String?
  public let approvalRef: String?
  public let operationRef: String?
  public let pluginRef: String?
  public let payloadDigest: String
  public let deduplicationKey: String?

  public init(
    subjectID: String,
    requestID: String? = nil,
    target: String? = nil,
    action: AuditAction,
    outcome: String,
    reasonCode: String,
    policyRef: String? = nil,
    planRef: String? = nil,
    approvalRef: String? = nil,
    operationRef: String? = nil,
    pluginRef: String? = nil,
    payloadDigest: String,
    deduplicationKey: String? = nil
  ) {
    self.subjectID = subjectID
    self.requestID = requestID
    self.target = target
    self.action = action
    self.outcome = outcome
    self.reasonCode = reasonCode
    self.policyRef = policyRef
    self.planRef = planRef
    self.approvalRef = approvalRef
    self.operationRef = operationRef
    self.pluginRef = pluginRef
    self.payloadDigest = payloadDigest
    self.deduplicationKey = deduplicationKey
  }
}

public enum AuditVerificationHealth: String, Codable, Equatable, Sendable {
  case healthy
  case recoverableAnchorLag
  case degraded
  case tampered
}

public struct AuditVerificationReport: Codable, Equatable, Sendable {
  public let health: AuditVerificationHealth
  public let recordCount: UInt64
  public let segmentCount: UInt64
  public let retainedCheckpointCount: UInt64
  public let activeKeyID: String?
  public let databaseHead: AuditChainHeadAnchor?
  public let externalHead: AuditChainHeadAnchor?
  public let findings: [String]

  public init(
    health: AuditVerificationHealth,
    recordCount: UInt64,
    segmentCount: UInt64,
    retainedCheckpointCount: UInt64,
    activeKeyID: String?,
    databaseHead: AuditChainHeadAnchor?,
    externalHead: AuditChainHeadAnchor?,
    findings: [String]
  ) {
    self.health = health
    self.recordCount = recordCount
    self.segmentCount = segmentCount
    self.retainedCheckpointCount = retainedCheckpointCount
    self.activeKeyID = activeKeyID
    self.databaseHead = databaseHead
    self.externalHead = externalHead
    self.findings = findings
  }
}

public struct AuditKeyMetadataExport: Codable, Equatable, Sendable {
  public let keyID: String
  public let generation: UInt64
  public let algorithm: String
  public let publicKeyX963Base64: String
  public let publicKeySHA256: String
  public let status: String
  public let priorKeyID: String?
  public let transitionSignatureDERBase64: String?
  public let createdAt: String
  public let retiredAt: String?
  public let revokedAt: String?
}

public struct AuditRecordExport: Codable, Equatable, Sendable {
  public let record: AuditRecord
  public let canonicalPreimageBase64: String
}

public struct AuditSegmentExport: Codable, Equatable, Sendable {
  public let ordinal: UInt64
  public let seal: AuditSegmentSeal
  public let firstRecordDigest: String
  public let lastRecordDigest: String
  public let openedAt: String
  public let sealedAt: String
}

public struct AuditRetentionExport: Codable, Equatable, Sendable {
  public let checkpointID: String
  public let removedThroughOrdinal: UInt64
  public let checkpoint: AuditRetentionCheckpoint
  public let canonicalPreimageBase64: String
}

public struct AuditExportBundle: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let generatedAt: String
  public let verification: AuditVerificationReport
  public let keys: [AuditKeyMetadataExport]
  public let segments: [AuditSegmentExport]
  public let records: [AuditRecordExport]
  public let retentionCheckpoints: [AuditRetentionExport]
}

public final class TamperEvidentAuditTrail: @unchecked Sendable {
  public static let genesisRetentionAnchor = "sha256:" + String(repeating: "0", count: 64)

  private let store: SQLiteStateStore
  private let keyStore: any AuditSigningKeyStoring
  private let now: @Sendable () -> Date
  private let lock = NSLock()

  public init(
    store: SQLiteStateStore,
    keyStore: any AuditSigningKeyStoring,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.keyStore = keyStore
    self.now = now
  }

  public func append(_ input: AuditAppendInput) throws -> AuditRecord {
    try Self.validate(input)
    lock.lock()
    defer { lock.unlock() }
    try assertExternalHeadAligned()
    let timestamp = Self.timestamp(now())
    let descriptor = try keyStore.activeKey()
    let result = try store.withValidatedConnection { connection in
      try connection.transaction {
        try ensureActiveKey(descriptor, timestamp: timestamp, connection: connection)
        let priorSegment = try Self.lastSegment(connection)
        let priorRecord = try Self.lastRecord(connection)
        let priorRetention = try Self.lastRetentionAnchor(connection)
        if let deduplicationKey = input.deduplicationKey,
          let existing = try Self.loadRecords(connection).first(where: {
            $0.deduplicationKey == deduplicationKey
          })
        {
          guard existing.record.subjectID == input.subjectID,
            existing.record.requestID == input.requestID,
            existing.record.target == input.target,
            existing.record.action == input.action,
            existing.record.outcome == input.outcome,
            existing.record.reasonCode == input.reasonCode,
            existing.record.policyRef == input.policyRef,
            existing.record.planRef == input.planRef,
            existing.record.approvalRef == input.approvalRef,
            existing.record.operationRef == input.operationRef,
            existing.record.pluginRef == input.pluginRef,
            existing.record.payloadDigest == input.payloadDigest,
            let priorSegment
          else { throw AuditTrailError.invalidInput("audit deduplication conflict") }
          return (
            existing.record,
            AuditChainHeadAnchor(
              segmentOrdinal: priorSegment.ordinal,
              segmentID: priorSegment.segmentID,
              segmentDigest: priorSegment.segmentDigest,
              keyID: priorSegment.keyID
            )
          )
        }
        if let priorRecord, Self.date(priorRecord.timestamp) > Self.date(timestamp) {
          throw AuditTrailError.clockRegression
        }
        if let priorRetention, Self.date(priorRetention.timestamp) > Self.date(timestamp) {
          throw AuditTrailError.clockRegression
        }
        let sequence = (priorRecord?.sequence ?? 0) + 1
        let ordinal = (priorSegment?.ordinal ?? 0) + 1
        let segmentID = "audit-segment:\(UUID().uuidString.lowercased())"
        let recordID = "audit-record:\(UUID().uuidString.lowercased())"
        let recordPreimage = AuditRecordPreimage(
          schemaVersion: 1,
          identifier: recordID,
          segmentID: segmentID,
          sequence: sequence,
          timestamp: timestamp,
          previousDigest: priorRecord?.recordDigest,
          subjectID: input.subjectID,
          requestID: input.requestID,
          target: input.target,
          action: input.action.rawValue,
          outcome: input.outcome,
          reasonCode: input.reasonCode,
          policyRef: input.policyRef,
          planRef: input.planRef,
          approvalRef: input.approvalRef,
          operationRef: input.operationRef,
          pluginRef: input.pluginRef,
          payloadDigest: input.payloadDigest,
          deduplicationKey: input.deduplicationKey,
          signingKeyID: descriptor.keyID
        )
        let canonicalRecord = try Self.canonical(recordPreimage)
        let recordDigest = Self.taggedDigest(canonicalRecord)
        let segmentPreimage = AuditSegmentPreimage(
          schemaVersion: 1,
          segmentID: segmentID,
          ordinal: ordinal,
          firstSequence: sequence,
          lastSequence: sequence,
          recordCount: 1,
          priorSegmentDigest: priorSegment?.segmentDigest,
          firstRecordDigest: recordDigest,
          lastRecordDigest: recordDigest,
          keyID: descriptor.keyID,
          openedAt: timestamp,
          sealedAt: timestamp
        )
        let canonicalSegment = try Self.canonical(segmentPreimage)
        let rawSegmentDigest = Self.rawDigest(canonicalSegment)
        let segmentDigest = Self.tagged(rawSegmentDigest)
        let signature: Data
        do {
          signature = try keyStore.sign(rawSegmentDigest, keyID: descriptor.keyID)
        } catch {
          throw AuditTrailError.signingFailed
        }
        try connection.run(
          """
          INSERT INTO audit_segments (
              segment_id, ordinal, first_sequence, last_sequence, record_count,
              prior_segment_digest, first_record_digest, last_record_digest,
              segment_digest, signature_der_base64, key_id, status, opened_at, sealed_at
          ) VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, 'sealed', ?, ?)
          """,
          bindings: [
            .text(segmentID), .int64(Int64(ordinal)), .int64(Int64(sequence)),
            .int64(Int64(sequence)), Self.binding(priorSegment?.segmentDigest),
            .text(recordDigest), .text(recordDigest), .text(segmentDigest),
            .text(signature.base64EncodedString()), .text(descriptor.keyID),
            .text(timestamp), .text(timestamp),
          ]
        )
        try connection.run(
          """
          INSERT INTO audit_records (
              record_id, segment_id, sequence, timestamp, previous_digest, subject_id,
              request_id, target, action, outcome, reason_code, policy_ref, plan_ref,
              approval_ref, operation_ref, plugin_ref, payload_digest, record_digest,
              signing_key_id, deduplication_key, canonical_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(recordID), .text(segmentID), .int64(Int64(sequence)), .text(timestamp),
            Self.binding(priorRecord?.recordDigest), .text(input.subjectID),
            Self.binding(input.requestID), Self.binding(input.target), .text(input.action.rawValue),
            .text(input.outcome), .text(input.reasonCode), Self.binding(input.policyRef),
            Self.binding(input.planRef), Self.binding(input.approvalRef),
            Self.binding(input.operationRef), Self.binding(input.pluginRef),
            .text(input.payloadDigest), .text(recordDigest), .text(descriptor.keyID),
            Self.binding(input.deduplicationKey),
            .text(String(decoding: canonicalRecord, as: UTF8.self)),
          ]
        )
        let record = AuditRecord(
          identifier: recordID,
          segmentID: segmentID,
          sequence: sequence,
          timestamp: Self.date(timestamp),
          previousDigest: priorRecord?.recordDigest,
          subjectID: input.subjectID,
          requestID: input.requestID,
          target: input.target,
          action: input.action,
          outcome: input.outcome,
          reasonCode: input.reasonCode,
          policyRef: input.policyRef,
          planRef: input.planRef,
          approvalRef: input.approvalRef,
          operationRef: input.operationRef,
          pluginRef: input.pluginRef,
          payloadDigest: input.payloadDigest,
          recordDigest: recordDigest,
          signingKeyID: descriptor.keyID
        )
        return (
          record,
          AuditChainHeadAnchor(
            segmentOrdinal: ordinal,
            segmentID: segmentID,
            segmentDigest: segmentDigest,
            keyID: descriptor.keyID
          )
        )
      }
    }
    do {
      try keyStore.storeHead(result.1)
    } catch {
      throw AuditTrailError.anchorMismatch
    }
    return result.0
  }

  public func verify() -> AuditVerificationReport {
    lock.lock()
    defer { lock.unlock() }
    do {
      return try verifyLocked()
    } catch {
      return AuditVerificationReport(
        health: .tampered,
        recordCount: 0,
        segmentCount: 0,
        retainedCheckpointCount: 0,
        activeKeyID: nil,
        databaseHead: nil,
        externalHead: try? keyStore.loadHead(),
        findings: [String(describing: error)]
      )
    }
  }

  public func recoverAnchorAfterVerifiedCrash() throws -> AuditChainHeadAnchor? {
    lock.lock()
    defer { lock.unlock() }
    let report = try verifyLocked()
    switch report.health {
    case .healthy:
      return report.databaseHead
    case .recoverableAnchorLag:
      guard let databaseHead = report.databaseHead else {
        throw AuditTrailError.anchorMismatch
      }
      try keyStore.storeHead(databaseHead)
      return databaseHead
    case .degraded, .tampered:
      throw AuditTrailError.anchorMismatch
    }
  }

  public func rotateSigningKey() throws -> AuditSigningKeyDescriptor {
    lock.lock()
    defer { lock.unlock() }
    try assertExternalHeadAligned()
    let timestamp = Self.timestamp(now())
    let current = try keyStore.activeKey()
    try store.withValidatedConnection { connection in
      try connection.transaction {
        try ensureActiveKey(current, timestamp: timestamp, connection: connection)
      }
    }
    let next = try keyStore.generateInactiveKey()
    let generation = try store.withValidatedConnection(readOnly: true) { connection in
      UInt64(try Self.scalarInt(connection, "SELECT COALESCE(MAX(generation), 0) FROM audit_key_metadata") + 1)
    }
    let transition = AuditKeyTransitionPreimage(
      schemaVersion: 1,
      generation: generation,
      priorKeyID: current.keyID,
      keyID: next.keyID,
      publicKeyX963Base64: next.publicKeyX963Base64,
      publicKeySHA256: next.publicKeySHA256,
      createdAt: timestamp
    )
    let signature: Data
    do {
      signature = try keyStore.sign(Self.rawDigest(try Self.canonical(transition)), keyID: current.keyID)
    } catch {
      throw AuditTrailError.keyRotationFailed
    }
    try store.withValidatedConnection { connection in
      try connection.run(
        """
        INSERT INTO audit_key_metadata (
            key_id, generation, algorithm, public_key_x963_base64, public_key_sha256,
            status, prior_key_id, transition_signature_der_base64, created_at
        ) VALUES (?, ?, 'p256-sha256', ?, ?, 'pending', ?, ?, ?)
        """,
        bindings: [
          .text(next.keyID), .int64(Int64(generation)), .text(next.publicKeyX963Base64),
          .text(next.publicKeySHA256), .text(current.keyID),
          .text(signature.base64EncodedString()), .text(timestamp),
        ]
      )
    }
    do {
      try keyStore.activate(keyID: next.keyID)
      try store.withValidatedConnection { connection in
        try connection.transaction {
          try connection.run(
            "UPDATE audit_key_metadata SET status = 'retired', retired_at = ? WHERE key_id = ? AND status = 'active'",
            bindings: [.text(timestamp), .text(current.keyID)]
          )
          try connection.run(
            "UPDATE audit_key_metadata SET status = 'active' WHERE key_id = ? AND status = 'pending'",
            bindings: [.text(next.keyID)]
          )
        }
      }
    } catch {
      throw AuditTrailError.keyRotationFailed
    }
    return next
  }

  @discardableResult
  public func recoverPendingKeyRotation() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let keys = try store.withValidatedConnection(readOnly: true) { connection in
      try Self.loadKeys(connection)
    }
    let pending = keys.filter { $0.status == "pending" }
    guard !pending.isEmpty else { return false }
    guard pending.count == 1,
      let next = pending.first,
      next.generation == keys.map(\.generation).max(),
      let priorID = next.priorKeyID,
      keys.contains(where: { $0.keyID == priorID && $0.status == "active" })
    else { throw AuditTrailError.keyRotationFailed }
    var findings: [String] = []
    try Self.verifyKeys(keys, findings: &findings)
    let configured = try keyStore.configuredActiveKey()
    if configured?.keyID == priorID {
      try keyStore.activate(keyID: next.keyID)
    } else if configured?.keyID != next.keyID {
      throw AuditTrailError.keyRotationFailed
    }
    let timestamp = Self.timestamp(now())
    try store.withValidatedConnection { connection in
      try connection.transaction {
        try connection.run(
          "UPDATE audit_key_metadata SET status = 'retired', retired_at = ? WHERE key_id = ? AND status = 'active'",
          bindings: [.text(timestamp), .text(priorID)]
        )
        try connection.run(
          "UPDATE audit_key_metadata SET status = 'active' WHERE key_id = ? AND status = 'pending'",
          bindings: [.text(next.keyID)]
        )
      }
    }
    return true
  }

  @discardableResult
  public func retainSealedSuffix(
    removingThroughOrdinal: UInt64,
    approver: String,
    reason: String
  ) throws -> AuditRetentionCheckpoint {
    guard Self.safe(approver, maximum: 128), Self.safe(reason, maximum: 512) else {
      throw AuditTrailError.invalidInput("retention approval")
    }
    lock.lock()
    defer { lock.unlock() }
    let report = try verifyLocked()
    guard report.health == .healthy,
      let head = report.databaseHead,
      removingThroughOrdinal > 0,
      removingThroughOrdinal < head.segmentOrdinal
    else { throw AuditTrailError.retentionRejected }
    let descriptor = try keyStore.activeKey()
    let timestamp = Self.timestamp(now())
    let checkpoint = try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let removed = try Self.segment(connection, ordinal: removingThroughOrdinal) else {
          throw AuditTrailError.retentionRejected
        }
        if let lastRecord = try Self.lastRecord(connection),
          Self.date(lastRecord.timestamp) > Self.date(timestamp)
        {
          throw AuditTrailError.clockRegression
        }
        if let lastRetention = try Self.lastRetentionAnchor(connection),
          Self.date(lastRetention.timestamp) > Self.date(timestamp)
        {
          throw AuditTrailError.clockRegression
        }
        let priorAnchor = try Self.lastRetentionAnchor(connection)?.newAnchorDigest
          ?? Self.genesisRetentionAnchor
        let checkpointID = "audit-retention:\(UUID().uuidString.lowercased())"
        let preimage = AuditRetentionPreimage(
          schemaVersion: 1,
          checkpointID: checkpointID,
          removedThroughSegmentID: removed.segmentID,
          removedThroughOrdinal: removingThroughOrdinal,
          priorAnchorDigest: priorAnchor,
          newAnchorDigest: removed.segmentDigest,
          approver: approver,
          reason: reason,
          timestamp: timestamp,
          keyID: descriptor.keyID
        )
        let canonical = try Self.canonical(preimage)
        let signature: Data
        do {
          signature = try keyStore.sign(Self.rawDigest(canonical), keyID: descriptor.keyID)
        } catch {
          throw AuditTrailError.signingFailed
        }
        try connection.run(
          """
          INSERT INTO audit_retention_anchors (
              checkpoint_id, removed_through_segment_id, removed_through_ordinal,
              prior_anchor_digest, new_anchor_digest, approver, reason, timestamp,
              signature_der_base64, key_id, canonical_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(checkpointID), .text(removed.segmentID), .int64(Int64(removingThroughOrdinal)),
            .text(priorAnchor), .text(removed.segmentDigest), .text(approver), .text(reason),
            .text(timestamp), .text(signature.base64EncodedString()), .text(descriptor.keyID),
            .text(String(decoding: canonical, as: UTF8.self)),
          ]
        )
        try connection.run(
          "DELETE FROM audit_segments WHERE ordinal <= ?",
          bindings: [.int64(Int64(removingThroughOrdinal))]
        )
        return AuditRetentionCheckpoint(
          removedThroughSegmentID: removed.segmentID,
          priorAnchorDigest: priorAnchor,
          newAnchorDigest: removed.segmentDigest,
          approver: approver,
          reason: reason,
          timestamp: Self.date(timestamp),
          p256Signature: signature.base64EncodedString(),
          keyID: descriptor.keyID
        )
      }
    }
    guard try verifyLocked().health == .healthy else {
      throw AuditTrailError.chainCorrupt("retention verification failed")
    }
    return checkpoint
  }

  public func exportVerified() throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    let report = try verifyLocked()
    guard report.health == .healthy else { throw AuditTrailError.chainCorrupt("export refused") }
    let bundle = try loadExport(report: report)
    return try Self.canonical(bundle)
  }

  public static func verifyExport(_ data: Data) throws -> AuditVerificationReport {
    let bundle = try JSONDecoder().decode(AuditExportBundle.self, from: data)
    guard bundle.schemaVersion == 1,
      try canonical(bundle) == data,
      date(bundle.generatedAt) != .distantPast
    else { throw AuditTrailError.chainCorrupt("audit export envelope changed") }
    let keys = bundle.keys.map {
      StoredKey(
        keyID: $0.keyID,
        generation: $0.generation,
        publicKeyX963Base64: $0.publicKeyX963Base64,
        publicKeySHA256: $0.publicKeySHA256,
        status: $0.status,
        priorKeyID: $0.priorKeyID,
        transitionSignature: $0.transitionSignatureDERBase64,
        createdAt: $0.createdAt,
        retiredAt: $0.retiredAt,
        revokedAt: $0.revokedAt
      )
    }
    let segments = bundle.segments.map {
      StoredSegment(
        segmentID: $0.seal.segmentID,
        ordinal: $0.ordinal,
        firstSequence: $0.seal.firstSequence,
        lastSequence: $0.seal.lastSequence,
        recordCount: $0.seal.recordCount,
        priorSegmentDigest: $0.seal.priorSegmentDigest,
        firstRecordDigest: $0.firstRecordDigest,
        lastRecordDigest: $0.lastRecordDigest,
        segmentDigest: $0.seal.sha256Digest,
        signature: $0.seal.p256Signature,
        keyID: $0.seal.keyID,
        openedAt: $0.openedAt,
        sealedAt: $0.sealedAt
      )
    }
    let records = try bundle.records.map { exported in
      guard let canonicalData = Data(base64Encoded: exported.canonicalPreimageBase64),
        canonicalData.base64EncodedString() == exported.canonicalPreimageBase64
      else { throw AuditTrailError.chainCorrupt("audit export record encoding changed") }
      let preimage = try JSONDecoder().decode(AuditRecordPreimage.self, from: canonicalData)
      return StoredRecord(
        sequence: exported.record.sequence,
        timestamp: preimage.timestamp,
        recordDigest: exported.record.recordDigest,
        canonicalJSON: String(decoding: canonicalData, as: UTF8.self),
        deduplicationKey: preimage.deduplicationKey,
        record: exported.record
      )
    }
    let retention = try bundle.retentionCheckpoints.map { exported in
      guard let canonicalData = Data(base64Encoded: exported.canonicalPreimageBase64),
        canonicalData.base64EncodedString() == exported.canonicalPreimageBase64
      else { throw AuditTrailError.chainCorrupt("audit export retention encoding changed") }
      let preimage = try JSONDecoder().decode(AuditRetentionPreimage.self, from: canonicalData)
      return StoredRetention(
        checkpointID: exported.checkpointID,
        removedThroughOrdinal: exported.removedThroughOrdinal,
        newAnchorDigest: exported.checkpoint.newAnchorDigest,
        timestamp: preimage.timestamp,
        canonicalJSON: String(decoding: canonicalData, as: UTF8.self),
        checkpoint: exported.checkpoint
      )
    }
    var findings: [String] = []
    try verifyKeys(keys, findings: &findings)
    try verifyRetention(retention, keys: keys, findings: &findings)
    try verifyChain(
      segments: segments,
      records: records,
      retention: retention,
      keys: keys,
      findings: &findings
    )
    let head = segments.last.map {
      AuditChainHeadAnchor(
        segmentOrdinal: $0.ordinal,
        segmentID: $0.segmentID,
        segmentDigest: $0.segmentDigest,
        keyID: $0.keyID
      )
    }
    guard findings.isEmpty,
      bundle.verification.health == .healthy,
      bundle.verification.databaseHead == head,
      bundle.verification.externalHead == head,
      bundle.verification.recordCount == UInt64(records.count),
      bundle.verification.segmentCount == UInt64(segments.count),
      bundle.verification.retainedCheckpointCount == UInt64(retention.count)
    else { throw AuditTrailError.chainCorrupt("audit export verification metadata changed") }
    return AuditVerificationReport(
      health: .healthy,
      recordCount: UInt64(records.count),
      segmentCount: UInt64(segments.count),
      retainedCheckpointCount: UInt64(retention.count),
      activeKeyID: keys.first(where: { $0.status == "active" })?.keyID,
      databaseHead: head,
      externalHead: head,
      findings: []
    )
  }

  private func verifyLocked() throws -> AuditVerificationReport {
    let externalHead = try keyStore.loadHead()
    let configuredKey = try keyStore.configuredActiveKey()
    return try store.withValidatedConnection(readOnly: true) { connection in
      let keys = try Self.loadKeys(connection)
      let segments = try Self.loadSegments(connection)
      let records = try Self.loadRecords(connection)
      let retention = try Self.loadRetention(connection)
      var findings: [String] = []
      try Self.verifyKeys(keys, findings: &findings)
      if let active = keys.first(where: { $0.status == "active" }) {
        guard configuredKey?.keyID == active.keyID,
          configuredKey?.publicKeyX963Base64 == active.publicKeyX963Base64,
          configuredKey?.publicKeySHA256 == active.publicKeySHA256
        else { throw AuditTrailError.chainCorrupt("active audit key changed") }
      }
      try Self.verifyRetention(retention, keys: keys, findings: &findings)
      try Self.verifyChain(
        segments: segments,
        records: records,
        retention: retention,
        keys: keys,
        findings: &findings
      )
      let databaseHead = segments.last.map {
        AuditChainHeadAnchor(
          segmentOrdinal: $0.ordinal,
          segmentID: $0.segmentID,
          segmentDigest: $0.segmentDigest,
          keyID: $0.keyID
        )
      }
      let health: AuditVerificationHealth
      if databaseHead == externalHead {
        health = findings.isEmpty ? .healthy : .degraded
      } else if Self.externalAnchorPrecedesDatabase(
        externalHead,
        databaseHead: databaseHead,
        segments: segments,
        retention: retention
      ) {
        findings.append("external audit head trails a fully verified database head")
        health = .recoverableAnchorLag
      } else if databaseHead == nil, externalHead == nil {
        health = findings.isEmpty ? .healthy : .degraded
      } else {
        findings.append("external audit head does not match the verified database chain")
        health = .tampered
      }
      return AuditVerificationReport(
        health: health,
        recordCount: UInt64(records.count),
        segmentCount: UInt64(segments.count),
        retainedCheckpointCount: UInt64(retention.count),
        activeKeyID: keys.first(where: { $0.status == "active" })?.keyID,
        databaseHead: databaseHead,
        externalHead: externalHead,
        findings: findings
      )
    }
  }

  private func assertExternalHeadAligned() throws {
    let report = try verifyLocked()
    guard report.health == .healthy else { throw AuditTrailError.anchorMismatch }
  }

  private func ensureActiveKey(
    _ descriptor: AuditSigningKeyDescriptor,
    timestamp: String,
    connection: SQLiteConnection
  ) throws {
    let rows = try connection.query(
      "SELECT key_id, public_key_x963_base64, public_key_sha256 FROM audit_key_metadata WHERE status = 'active'"
    )
    if rows.isEmpty {
      let count = try Self.scalarInt(connection, "SELECT COUNT(*) FROM audit_key_metadata")
      guard count == 0 else { throw AuditTrailError.keyRotationFailed }
      try connection.run(
        """
        INSERT INTO audit_key_metadata (
            key_id, generation, algorithm, public_key_x963_base64, public_key_sha256,
            status, created_at
        ) VALUES (?, 1, 'p256-sha256', ?, ?, 'active', ?)
        """,
        bindings: [
          .text(descriptor.keyID), .text(descriptor.publicKeyX963Base64),
          .text(descriptor.publicKeySHA256), .text(timestamp),
        ]
      )
      return
    }
    guard rows.count == 1, rows[0].count == 3,
      rows[0][0] == descriptor.keyID,
      rows[0][1] == descriptor.publicKeyX963Base64,
      rows[0][2] == descriptor.publicKeySHA256
    else { throw AuditTrailError.keyRotationFailed }
  }

  private func loadExport(report: AuditVerificationReport) throws -> AuditExportBundle {
    try store.withValidatedConnection(readOnly: true) { connection in
      let keys = try Self.loadKeys(connection).map(\.export)
      let records = try Self.loadRecords(connection).map { stored in
        AuditRecordExport(
          record: stored.record,
          canonicalPreimageBase64: Data(stored.canonicalJSON.utf8).base64EncodedString()
        )
      }
      let segments = try Self.loadSegments(connection).map { stored in
        AuditSegmentExport(
          ordinal: stored.ordinal,
          seal: stored.seal,
          firstRecordDigest: stored.firstRecordDigest,
          lastRecordDigest: stored.lastRecordDigest,
          openedAt: stored.openedAt,
          sealedAt: stored.sealedAt
        )
      }
      let checkpoints = try Self.loadRetention(connection).map { stored in
        AuditRetentionExport(
          checkpointID: stored.checkpointID,
          removedThroughOrdinal: stored.removedThroughOrdinal,
          checkpoint: stored.checkpoint,
          canonicalPreimageBase64: Data(stored.canonicalJSON.utf8).base64EncodedString()
        )
      }
      return AuditExportBundle(
        schemaVersion: 1,
        generatedAt: Self.timestamp(now()),
        verification: report,
        keys: keys,
        segments: segments,
        records: records,
        retentionCheckpoints: checkpoints
      )
    }
  }
}

extension TamperEvidentAuditTrail: ControlSecurityAuditRecording {
  @discardableResult
  public func record(_ event: ControlSecurityAuditEvent) throws -> AuditRecord {
    try event.validate()
    return try append(
      AuditAppendInput(
        subjectID: event.subjectID,
        requestID: event.requestID,
        target: event.target,
        action: event.action,
        outcome: event.outcome,
        reasonCode: event.reasonCode,
        operationRef: event.operationRef,
        payloadDigest: event.payloadDigest,
        deduplicationKey: event.deduplicationKey
      )
    )
  }
}

private extension TamperEvidentAuditTrail {
  struct AuditRecordPreimage: Codable {
    let schemaVersion: Int
    let identifier: String
    let segmentID: String
    let sequence: UInt64
    let timestamp: String
    let previousDigest: String?
    let subjectID: String
    let requestID: String?
    let target: String?
    let action: String
    let outcome: String
    let reasonCode: String
    let policyRef: String?
    let planRef: String?
    let approvalRef: String?
    let operationRef: String?
    let pluginRef: String?
    let payloadDigest: String
    let deduplicationKey: String?
    let signingKeyID: String
  }

  struct AuditSegmentPreimage: Codable {
    let schemaVersion: Int
    let segmentID: String
    let ordinal: UInt64
    let firstSequence: UInt64
    let lastSequence: UInt64
    let recordCount: UInt64
    let priorSegmentDigest: String?
    let firstRecordDigest: String
    let lastRecordDigest: String
    let keyID: String
    let openedAt: String
    let sealedAt: String
  }

  struct AuditKeyTransitionPreimage: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let priorKeyID: String
    let keyID: String
    let publicKeyX963Base64: String
    let publicKeySHA256: String
    let createdAt: String
  }

  struct AuditRetentionPreimage: Codable {
    let schemaVersion: Int
    let checkpointID: String
    let removedThroughSegmentID: String
    let removedThroughOrdinal: UInt64
    let priorAnchorDigest: String
    let newAnchorDigest: String
    let approver: String
    let reason: String
    let timestamp: String
    let keyID: String
  }

  struct StoredKey {
    let keyID: String
    let generation: UInt64
    let publicKeyX963Base64: String
    let publicKeySHA256: String
    let status: String
    let priorKeyID: String?
    let transitionSignature: String?
    let createdAt: String
    let retiredAt: String?
    let revokedAt: String?

    var export: AuditKeyMetadataExport {
      AuditKeyMetadataExport(
        keyID: keyID,
        generation: generation,
        algorithm: "p256-sha256",
        publicKeyX963Base64: publicKeyX963Base64,
        publicKeySHA256: publicKeySHA256,
        status: status,
        priorKeyID: priorKeyID,
        transitionSignatureDERBase64: transitionSignature,
        createdAt: createdAt,
        retiredAt: retiredAt,
        revokedAt: revokedAt
      )
    }
  }

  struct StoredSegment {
    let segmentID: String
    let ordinal: UInt64
    let firstSequence: UInt64
    let lastSequence: UInt64
    let recordCount: UInt64
    let priorSegmentDigest: String?
    let firstRecordDigest: String
    let lastRecordDigest: String
    let segmentDigest: String
    let signature: String
    let keyID: String
    let openedAt: String
    let sealedAt: String

    var seal: AuditSegmentSeal {
      AuditSegmentSeal(
        segmentID: segmentID,
        firstSequence: firstSequence,
        lastSequence: lastSequence,
        recordCount: recordCount,
        priorSegmentDigest: priorSegmentDigest,
        sha256Digest: segmentDigest,
        p256Signature: signature,
        keyID: keyID
      )
    }
  }

  struct StoredRecord {
    let sequence: UInt64
    let timestamp: String
    let recordDigest: String
    let canonicalJSON: String
    let deduplicationKey: String?
    let record: AuditRecord
  }

  struct StoredRetention {
    let checkpointID: String
    let removedThroughOrdinal: UInt64
    let newAnchorDigest: String
    let timestamp: String
    let canonicalJSON: String
    let checkpoint: AuditRetentionCheckpoint
  }

  static func validate(_ input: AuditAppendInput) throws {
    guard safe(input.subjectID, maximum: 128), optionalSafe(input.requestID, maximum: 128),
      optionalSafe(input.target, maximum: 512), safe(input.outcome, maximum: 128),
      safe(input.reasonCode, maximum: 128), optionalSafe(input.policyRef, maximum: 512),
      optionalSafe(input.planRef, maximum: 512), optionalSafe(input.approvalRef, maximum: 512),
      optionalSafe(input.operationRef, maximum: 512), optionalSafe(input.pluginRef, maximum: 512),
      optionalSafe(input.deduplicationKey, maximum: 256),
      digest(input.payloadDigest)
    else { throw AuditTrailError.invalidInput("audit append") }
  }

  static func safe(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0")
  }

  static func optionalSafe(_ value: String?, maximum: Int) -> Bool {
    value.map { safe($0, maximum: maximum) } ?? true
  }

  static func digest(_ value: String) -> Bool {
    value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
  }

  static func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func rawDigest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
  static func taggedDigest(_ data: Data) -> String { tagged(rawDigest(data)) }
  static func tagged(_ digest: Data) -> String {
    "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  static func raw(_ tagged: String) throws -> Data {
    guard digest(tagged) else { throw AuditTrailError.chainCorrupt("invalid digest") }
    var bytes = Data(capacity: 32)
    let hex = tagged.dropFirst("sha256:".count)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else {
        throw AuditTrailError.chainCorrupt("invalid digest")
      }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func date(_ value: String) -> Date {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value) ?? .distantPast
  }

  static func binding(_ value: String?) -> SQLiteValue {
    guard let value else { return .null }
    return .text(value)
  }

  static func scalarInt(_ connection: SQLiteConnection, _ sql: String) throws -> Int64 {
    guard let value = try connection.query(sql).first?.first ?? nil, let result = Int64(value) else {
      throw AuditTrailError.chainCorrupt("invalid scalar")
    }
    return result
  }

  static func lastSegment(_ connection: SQLiteConnection) throws -> StoredSegment? {
    try loadSegments(connection).last
  }

  static func segment(_ connection: SQLiteConnection, ordinal: UInt64) throws -> StoredSegment? {
    try loadSegments(connection).first { $0.ordinal == ordinal }
  }

  static func lastRecord(_ connection: SQLiteConnection) throws -> StoredRecord? {
    try loadRecords(connection).last
  }

  static func lastRetentionAnchor(_ connection: SQLiteConnection) throws -> StoredRetention? {
    try loadRetention(connection).last
  }

  static func loadKeys(_ connection: SQLiteConnection) throws -> [StoredKey] {
    try connection.query(
      """
      SELECT key_id, generation, public_key_x963_base64, public_key_sha256, status,
             prior_key_id, transition_signature_der_base64, created_at, retired_at, revoked_at
      FROM audit_key_metadata ORDER BY generation
      """
    ).map { row in
      guard row.count == 10, let keyID = row[0], let generation = row[1].flatMap(UInt64.init),
        let publicKey = row[2], let digest = row[3], let status = row[4], let created = row[7]
      else { throw AuditTrailError.chainCorrupt("invalid key metadata") }
      return StoredKey(
        keyID: keyID, generation: generation, publicKeyX963Base64: publicKey,
        publicKeySHA256: digest, status: status, priorKeyID: row[5],
        transitionSignature: row[6], createdAt: created, retiredAt: row[8], revokedAt: row[9]
      )
    }
  }

  static func loadSegments(_ connection: SQLiteConnection) throws -> [StoredSegment] {
    try connection.query(
      """
      SELECT segment_id, ordinal, first_sequence, last_sequence, record_count,
             prior_segment_digest, first_record_digest, last_record_digest,
             segment_digest, signature_der_base64, key_id, opened_at, sealed_at
      FROM audit_segments ORDER BY ordinal
      """
    ).map { row in
      guard row.count == 13, let id = row[0], let ordinal = row[1].flatMap(UInt64.init),
        let first = row[2].flatMap(UInt64.init), let last = row[3].flatMap(UInt64.init),
        let count = row[4].flatMap(UInt64.init), let firstDigest = row[6],
        let lastDigest = row[7], let digest = row[8], let signature = row[9],
        let keyID = row[10], let opened = row[11], let sealed = row[12]
      else { throw AuditTrailError.chainCorrupt("invalid segment") }
      return StoredSegment(
        segmentID: id, ordinal: ordinal, firstSequence: first, lastSequence: last,
        recordCount: count, priorSegmentDigest: row[5], firstRecordDigest: firstDigest,
        lastRecordDigest: lastDigest, segmentDigest: digest, signature: signature,
        keyID: keyID, openedAt: opened, sealedAt: sealed
      )
    }
  }

  static func loadRecords(_ connection: SQLiteConnection) throws -> [StoredRecord] {
    try connection.query(
      """
      SELECT record_id, segment_id, sequence, timestamp, previous_digest, subject_id,
             request_id, target, action, outcome, reason_code, policy_ref, plan_ref,
             approval_ref, operation_ref, plugin_ref, payload_digest, record_digest,
             signing_key_id, deduplication_key, canonical_json
      FROM audit_records ORDER BY sequence
      """
    ).map { row in
      guard row.count == 21, let recordID = row[0], let segmentID = row[1],
        let sequence = row[2].flatMap(UInt64.init), let timestamp = row[3], let subject = row[5],
        let actionRaw = row[8], let action = AuditAction(rawValue: actionRaw), let outcome = row[9],
        let reason = row[10], let payload = row[16], let recordDigest = row[17],
        let keyID = row[18], let canonical = row[20]
      else { throw AuditTrailError.chainCorrupt("invalid audit record") }
      return StoredRecord(
        sequence: sequence,
        timestamp: timestamp,
        recordDigest: recordDigest,
        canonicalJSON: canonical,
        deduplicationKey: row[19],
        record: AuditRecord(
          identifier: recordID, segmentID: segmentID, sequence: sequence,
          timestamp: date(timestamp), previousDigest: row[4], subjectID: subject,
          requestID: row[6], target: row[7], action: action, outcome: outcome,
          reasonCode: reason, policyRef: row[11], planRef: row[12], approvalRef: row[13],
          operationRef: row[14], pluginRef: row[15], payloadDigest: payload,
          recordDigest: recordDigest, signingKeyID: keyID
        )
      )
    }
  }

  static func loadRetention(_ connection: SQLiteConnection) throws -> [StoredRetention] {
    try connection.query(
      """
      SELECT checkpoint_id, removed_through_segment_id, removed_through_ordinal,
             prior_anchor_digest, new_anchor_digest, approver, reason, timestamp,
             signature_der_base64, key_id, canonical_json
      FROM audit_retention_anchors ORDER BY removed_through_ordinal
      """
    ).map { row in
      guard row.count == 11, let id = row[0], let segmentID = row[1],
        let ordinal = row[2].flatMap(UInt64.init), let prior = row[3], let next = row[4],
        let approver = row[5], let reason = row[6], let timestamp = row[7],
        let signature = row[8], let keyID = row[9], let canonical = row[10]
      else { throw AuditTrailError.chainCorrupt("invalid retention checkpoint") }
      return StoredRetention(
        checkpointID: id,
        removedThroughOrdinal: ordinal,
        newAnchorDigest: next,
        timestamp: timestamp,
        canonicalJSON: canonical,
        checkpoint: AuditRetentionCheckpoint(
          removedThroughSegmentID: segmentID, priorAnchorDigest: prior,
          newAnchorDigest: next, approver: approver, reason: reason,
          timestamp: date(timestamp), p256Signature: signature, keyID: keyID
        )
      )
    }
  }

  static func verifyKeys(_ keys: [StoredKey], findings: inout [String]) throws {
    let active = keys.filter { $0.status == "active" }
    let pending = keys.filter { $0.status == "pending" }
    guard keys.isEmpty || active.count == 1 else {
      throw AuditTrailError.chainCorrupt("audit key set must have one active key")
    }
    guard pending.count <= 1,
      pending.first.map({ $0.generation == keys.map(\.generation).max() }) ?? true,
      pending.first.map({ pendingKey in
        pendingKey.priorKeyID == active.first?.keyID
      }) ?? true
    else {
      throw AuditTrailError.chainCorrupt("invalid pending audit key state")
    }
    for (index, key) in keys.enumerated() {
      guard key.generation == UInt64(index + 1),
        date(key.createdAt) != .distantPast,
        key.retiredAt.map({ date($0) >= date(key.createdAt) }) ?? true,
        key.revokedAt.map({ date($0) >= date(key.createdAt) }) ?? true,
        let publicData = Data(base64Encoded: key.publicKeyX963Base64),
        rawDigest(publicData).map({ String(format: "%02x", $0) }).joined() == key.publicKeySHA256,
        "p256:\(key.publicKeySHA256)" == key.keyID,
        (try? P256.Signing.PublicKey(x963Representation: publicData)) != nil
      else { throw AuditTrailError.chainCorrupt("audit key metadata changed") }
      switch key.status {
      case "active", "pending":
        guard key.retiredAt == nil, key.revokedAt == nil else {
          throw AuditTrailError.chainCorrupt("audit key status metadata changed")
        }
      case "retired":
        guard key.retiredAt != nil, key.revokedAt == nil else {
          throw AuditTrailError.chainCorrupt("audit key status metadata changed")
        }
      case "revoked":
        guard key.revokedAt != nil else {
          throw AuditTrailError.chainCorrupt("audit key status metadata changed")
        }
      default:
        throw AuditTrailError.chainCorrupt("audit key status changed")
      }
      if index == 0 {
        guard key.priorKeyID == nil, key.transitionSignature == nil else {
          throw AuditTrailError.chainCorrupt("invalid initial audit key")
        }
      } else {
        let prior = keys[index - 1]
        guard date(key.createdAt) >= date(prior.createdAt),
          key.priorKeyID == prior.keyID,
          let signatureText = key.transitionSignature,
          let signatureData = Data(base64Encoded: signatureText),
          let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
          let priorPublicData = Data(base64Encoded: prior.publicKeyX963Base64),
          let priorPublic = try? P256.Signing.PublicKey(x963Representation: priorPublicData),
          let transition = try? canonical(
            AuditKeyTransitionPreimage(
              schemaVersion: 1, generation: key.generation, priorKeyID: prior.keyID,
              keyID: key.keyID, publicKeyX963Base64: key.publicKeyX963Base64,
              publicKeySHA256: key.publicKeySHA256, createdAt: key.createdAt
            )),
          priorPublic.isValidSignature(signature, for: rawDigest(transition))
        else { throw AuditTrailError.chainCorrupt("audit key transition changed") }
      }
      if key.status == "pending" { findings.append("audit key rotation is pending recovery") }
    }
  }

  static func verifyRetention(
    _ checkpoints: [StoredRetention],
    keys: [StoredKey],
    findings: inout [String]
  ) throws {
    let byID = Dictionary(uniqueKeysWithValues: keys.map { ($0.keyID, $0) })
    var priorAnchor = genesisRetentionAnchor
    var priorOrdinal: UInt64 = 0
    var priorTimestamp = Date.distantPast
    for stored in checkpoints {
      let checkpoint = stored.checkpoint
      guard stored.removedThroughOrdinal > priorOrdinal,
        date(stored.timestamp) >= priorTimestamp,
        checkpoint.priorAnchorDigest == priorAnchor,
        let key = byID[checkpoint.keyID],
        let publicData = Data(base64Encoded: key.publicKeyX963Base64),
        let publicKey = try? P256.Signing.PublicKey(x963Representation: publicData),
        let signatureData = Data(base64Encoded: checkpoint.p256Signature),
        let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
        let expectedCanonical = try? canonical(
          AuditRetentionPreimage(
            schemaVersion: 1,
            checkpointID: stored.checkpointID,
            removedThroughSegmentID: checkpoint.removedThroughSegmentID,
            removedThroughOrdinal: stored.removedThroughOrdinal,
            priorAnchorDigest: checkpoint.priorAnchorDigest,
            newAnchorDigest: checkpoint.newAnchorDigest,
            approver: checkpoint.approver,
            reason: checkpoint.reason,
            timestamp: stored.timestamp,
            keyID: checkpoint.keyID
          )),
        expectedCanonical == Data(stored.canonicalJSON.utf8),
        publicKey.isValidSignature(signature, for: rawDigest(expectedCanonical))
      else { throw AuditTrailError.chainCorrupt("retention checkpoint changed") }
      priorAnchor = checkpoint.newAnchorDigest
      priorOrdinal = stored.removedThroughOrdinal
      priorTimestamp = date(stored.timestamp)
    }
  }

  static func verifyChain(
    segments: [StoredSegment],
    records: [StoredRecord],
    retention: [StoredRetention],
    keys: [StoredKey],
    findings: inout [String]
  ) throws {
    guard segments.count == records.count else {
      throw AuditTrailError.chainCorrupt("segment and record counts differ")
    }
    let byID = Dictionary(uniqueKeysWithValues: keys.map { ($0.keyID, $0) })
    let retainedThrough = retention.last?.removedThroughOrdinal ?? 0
    let retainedDigest = retention.last?.newAnchorDigest
    var priorSegmentDigest = retainedDigest
    var priorRecordDigest: String?
    var priorTimestamp: Date?
    for (index, segment) in segments.enumerated() {
      let record = records[index]
      guard segment.ordinal == retainedThrough + UInt64(index) + 1,
        segment.firstSequence == record.sequence,
        segment.lastSequence == record.sequence,
        segment.recordCount == 1,
        segment.firstRecordDigest == record.recordDigest,
        segment.lastRecordDigest == record.recordDigest,
        segment.priorSegmentDigest == priorSegmentDigest,
        segment.segmentID == record.record.segmentID,
        record.record.previousDigest == priorRecordDigest || (index == 0 && retainedThrough > 0),
        let key = byID[segment.keyID],
        key.keyID == record.record.signingKeyID,
        let publicData = Data(base64Encoded: key.publicKeyX963Base64),
        let publicKey = try? P256.Signing.PublicKey(x963Representation: publicData),
        let signatureData = Data(base64Encoded: segment.signature),
        let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData)
      else { throw AuditTrailError.chainCorrupt("audit chain changed") }
      let expectedRecord = AuditRecordPreimage(
        schemaVersion: record.record.schemaVersion,
        identifier: record.record.identifier,
        segmentID: record.record.segmentID,
        sequence: record.record.sequence,
        timestamp: record.timestamp,
        previousDigest: record.record.previousDigest,
        subjectID: record.record.subjectID,
        requestID: record.record.requestID,
        target: record.record.target,
        action: record.record.action.rawValue,
        outcome: record.record.outcome,
        reasonCode: record.record.reasonCode,
        policyRef: record.record.policyRef,
        planRef: record.record.planRef,
        approvalRef: record.record.approvalRef,
        operationRef: record.record.operationRef,
        pluginRef: record.record.pluginRef,
        payloadDigest: record.record.payloadDigest,
        deduplicationKey: record.deduplicationKey,
        signingKeyID: record.record.signingKeyID
      )
      let expectedRecordData = try canonical(expectedRecord)
      guard expectedRecordData == Data(record.canonicalJSON.utf8),
        taggedDigest(expectedRecordData) == record.recordDigest,
        (try? record.record.validate()) != nil,
        (try? segment.seal.validate()) != nil
      else { throw AuditTrailError.chainCorrupt("audit record preimage changed") }
      let segmentPreimage = AuditSegmentPreimage(
        schemaVersion: 1, segmentID: segment.segmentID, ordinal: segment.ordinal,
        firstSequence: segment.firstSequence, lastSequence: segment.lastSequence,
        recordCount: segment.recordCount, priorSegmentDigest: segment.priorSegmentDigest,
        firstRecordDigest: segment.firstRecordDigest, lastRecordDigest: segment.lastRecordDigest,
        keyID: segment.keyID, openedAt: segment.openedAt, sealedAt: segment.sealedAt
      )
      let rawSegment = rawDigest(try canonical(segmentPreimage))
      guard tagged(rawSegment) == segment.segmentDigest,
        publicKey.isValidSignature(signature, for: rawSegment)
      else { throw AuditTrailError.chainCorrupt("audit segment signature changed") }
      let currentDate = date(record.timestamp)
      if let priorTimestamp, currentDate < priorTimestamp {
        throw AuditTrailError.chainCorrupt("audit clock moved backwards")
      }
      priorTimestamp = currentDate
      priorSegmentDigest = segment.segmentDigest
      priorRecordDigest = record.recordDigest
    }
  }

  static func externalAnchorPrecedesDatabase(
    _ external: AuditChainHeadAnchor?,
    databaseHead: AuditChainHeadAnchor?,
    segments: [StoredSegment],
    retention: [StoredRetention]
  ) -> Bool {
    guard let databaseHead else { return false }
    guard let external else { return !segments.isEmpty }
    guard external.segmentOrdinal < databaseHead.segmentOrdinal else { return false }
    if let segment = segments.first(where: { $0.ordinal == external.segmentOrdinal }) {
      return segment.segmentID == external.segmentID && segment.segmentDigest == external.segmentDigest
    }
    return retention.contains {
      $0.removedThroughOrdinal >= external.segmentOrdinal
        && $0.newAnchorDigest == external.segmentDigest
    }
  }
}
