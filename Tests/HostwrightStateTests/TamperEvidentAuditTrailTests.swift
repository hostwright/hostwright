import Foundation
import Security
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightState

final class TamperEvidentAuditTrailTests: XCTestCase {
  func testAppendVerifyAndExportHappyPath() throws {
    try withTrail { trail, _, _ in
      let first = try trail.append(input(requestID: "request-1", action: .request))
      let second = try trail.append(input(requestID: "request-2", action: .authorization))
      let third = try trail.append(input(requestID: "request-3", action: .operation))

      XCTAssertEqual([first.sequence, second.sequence, third.sequence], [1, 2, 3])
      XCTAssertEqual(first.previousDigest, nil)
      XCTAssertEqual(second.previousDigest, first.recordDigest)
      XCTAssertEqual(third.previousDigest, second.recordDigest)

      let report = trail.verify()
      XCTAssertEqual(report.health, .healthy)
      XCTAssertEqual(report.recordCount, 3)
      XCTAssertEqual(report.segmentCount, 3)
      XCTAssertEqual(report.databaseHead, report.externalHead)

      let export = try JSONDecoder().decode(AuditExportBundle.self, from: trail.exportVerified())
      XCTAssertEqual(export.verification.health, .healthy)
      XCTAssertEqual(export.records.map(\.record.sequence), [1, 2, 3])
      XCTAssertEqual(export.segments.count, 3)
      XCTAssertEqual(export.keys.count, 1)
      let exportedData = try trail.exportVerified()
      XCTAssertEqual(
        try TamperEvidentAuditTrail.verifyExport(exportedData).health,
        .healthy
      )
      let encodedPreimage = try XCTUnwrap(export.records.first?.canonicalPreimageBase64)
      let replacement = (encodedPreimage.last == "A" ? "B" : "A")
      let changedPreimage = String(encodedPreimage.dropLast()) + replacement
      let tampered = String(decoding: exportedData, as: UTF8.self)
        .replacingOccurrences(of: encodedPreimage, with: changedPreimage)
      XCTAssertThrowsError(
        try TamperEvidentAuditTrail.verifyExport(Data(tampered.utf8))
      )
    }
  }

  func testModificationDeletionReorderAndTruncationAreDetected() throws {
    try assertTamperingDetected { connection in
      try connection.run(
        "UPDATE audit_records SET canonical_json = '{}' WHERE sequence = 2")
    }
    try assertTamperingDetected { connection in
      try connection.run("DELETE FROM audit_segments WHERE ordinal = 2")
    }
    try assertTamperingDetected { connection in
      try connection.run("UPDATE audit_segments SET ordinal = 99 WHERE ordinal = 2")
    }
    try assertTamperingDetected { connection in
      try connection.run("DELETE FROM audit_segments WHERE ordinal = 3")
    }
  }

  func testP256RotationContinuityAndSignedPrefixRetention() throws {
    try withTrail { trail, _, _ in
      let first = try trail.append(input(requestID: "request-1", action: .request))
      let second = try trail.append(input(requestID: "request-2", action: .authorization))
      let nextKey = try trail.rotateSigningKey()
      let third = try trail.append(input(requestID: "request-3", action: .admission))
      _ = try trail.append(input(requestID: "request-4", action: .operation))

      XCTAssertNotEqual(first.signingKeyID, nextKey.keyID)
      XCTAssertEqual(third.signingKeyID, nextKey.keyID)
      XCTAssertEqual(trail.verify().health, .healthy)

      let checkpoint = try trail.retainSealedSuffix(
        removingThroughOrdinal: 2,
        approver: "owner",
        reason: "approved retention policy"
      )
      XCTAssertEqual(checkpoint.removedThroughSegmentID, second.segmentID)
      XCTAssertEqual(trail.verify().health, .healthy)

      let export = try JSONDecoder().decode(AuditExportBundle.self, from: trail.exportVerified())
      XCTAssertEqual(export.keys.count, 2)
      XCTAssertEqual(export.keys.filter { $0.status == "active" }.map(\.keyID), [nextKey.keyID])
      XCTAssertEqual(export.retentionCheckpoints.count, 1)
      XCTAssertEqual(export.records.map(\.record.sequence), [3, 4])
      XCTAssertEqual(export.segments.map(\.ordinal), [3, 4])
    }
  }

  func testSigningFailureAndExternalHeadStoreCrashRecovery() throws {
    try withTrail { trail, _, keyStore in
      keyStore.failSigning = true
      XCTAssertThrowsError(try trail.append(input(requestID: "request-fail", action: .request))) {
        XCTAssertEqual($0 as? AuditTrailError, .signingFailed)
      }
      XCTAssertEqual(trail.verify().health, .healthy)

      keyStore.failSigning = false
      keyStore.failHeadStore = true
      XCTAssertThrowsError(try trail.append(input(requestID: "request-crash", action: .operation))) {
        XCTAssertEqual($0 as? AuditTrailError, .anchorMismatch)
      }
      XCTAssertEqual(trail.verify().health, .recoverableAnchorLag)

      keyStore.failHeadStore = false
      let recovered = try trail.recoverAnchorAfterVerifiedCrash()
      XCTAssertNotNil(recovered)
      XCTAssertEqual(trail.verify().health, .healthy)
    }
  }

  func testBackwardClockIsRejectedWithoutCorruptingTheTrail() throws {
    let clock = LockedDate(Self.date("2026-08-02T20:00:00Z"))
    try withTrail(now: { clock.value }) { trail, _, _ in
      _ = try trail.append(input(requestID: "request-1", action: .request))
      clock.value = Self.date("2026-08-02T19:59:59Z")
      XCTAssertThrowsError(try trail.append(input(requestID: "request-2", action: .operation))) {
        XCTAssertEqual($0 as? AuditTrailError, .clockRegression)
      }
      let report = trail.verify()
      XCTAssertEqual(report.health, .healthy)
      XCTAssertEqual(report.recordCount, 1)
    }
  }

  func testKeyStatusTamperingIsDetectedBeforeVerifyOrExport() throws {
    for mutation in [
      "UPDATE audit_key_metadata SET status = 'retired', retired_at = '2026-08-02T20:01:00Z' WHERE status = 'active'",
      "UPDATE audit_key_metadata SET status = 'revoked', revoked_at = '2026-08-02T20:01:00Z' WHERE status = 'active'",
    ] {
      try withTrail { trail, store, _ in
        _ = try trail.append(input(requestID: "request-1", action: .request))
        try store.withValidatedConnection { connection in
          try connection.run(mutation)
        }

        XCTAssertEqual(trail.verify().health, .tampered)
        XCTAssertThrowsError(try trail.exportVerified())
      }
    }
  }

  func testDeduplicationRejectsEveryChangedSignedSecurityField() throws {
    try withTrail { trail, _, _ in
      let original = AuditAppendInput(
        subjectID: "owner",
        requestID: "request-1",
        target: "project:one",
        action: .authorization,
        outcome: "allowed",
        reasonCode: "roleAllowed",
        policyRef: "policy:one",
        planRef: "plan:one",
        approvalRef: "approval:one",
        operationRef: "operation:one",
        pluginRef: "plugin:one",
        payloadDigest: "sha256:" + String(repeating: "a", count: 64),
        deduplicationKey: "dedup:one"
      )
      let first = try trail.append(original)
      XCTAssertEqual(try trail.append(original).identifier, first.identifier)

      let conflicts = [
        AuditAppendInput(subjectID: "owner", requestID: "request-1", target: "project:two", action: .authorization, outcome: "allowed", reasonCode: "roleAllowed", policyRef: "policy:one", planRef: "plan:one", approvalRef: "approval:one", operationRef: "operation:one", pluginRef: "plugin:one", payloadDigest: original.payloadDigest, deduplicationKey: "dedup:one"),
        AuditAppendInput(subjectID: "owner", requestID: "request-1", target: "project:one", action: .authorization, outcome: "allowed", reasonCode: "roleAllowed", policyRef: "policy:two", planRef: "plan:one", approvalRef: "approval:one", operationRef: "operation:one", pluginRef: "plugin:one", payloadDigest: original.payloadDigest, deduplicationKey: "dedup:one"),
        AuditAppendInput(subjectID: "owner", requestID: "request-1", target: "project:one", action: .authorization, outcome: "allowed", reasonCode: "roleAllowed", policyRef: "policy:one", planRef: "plan:two", approvalRef: "approval:one", operationRef: "operation:one", pluginRef: "plugin:one", payloadDigest: original.payloadDigest, deduplicationKey: "dedup:one"),
        AuditAppendInput(subjectID: "owner", requestID: "request-1", target: "project:one", action: .authorization, outcome: "allowed", reasonCode: "roleAllowed", policyRef: "policy:one", planRef: "plan:one", approvalRef: "approval:two", operationRef: "operation:one", pluginRef: "plugin:one", payloadDigest: original.payloadDigest, deduplicationKey: "dedup:one"),
        AuditAppendInput(subjectID: "owner", requestID: "request-1", target: "project:one", action: .authorization, outcome: "allowed", reasonCode: "roleAllowed", policyRef: "policy:one", planRef: "plan:one", approvalRef: "approval:one", operationRef: "operation:two", pluginRef: "plugin:one", payloadDigest: original.payloadDigest, deduplicationKey: "dedup:one"),
        AuditAppendInput(subjectID: "owner", requestID: "request-1", target: "project:one", action: .authorization, outcome: "allowed", reasonCode: "roleAllowed", policyRef: "policy:one", planRef: "plan:one", approvalRef: "approval:one", operationRef: "operation:one", pluginRef: "plugin:two", payloadDigest: original.payloadDigest, deduplicationKey: "dedup:one"),
      ]
      for conflict in conflicts {
        XCTAssertThrowsError(try trail.append(conflict)) {
          XCTAssertEqual(
            $0 as? AuditTrailError,
            .invalidInput("audit deduplication conflict")
          )
        }
      }
      XCTAssertEqual(trail.verify().recordCount, 1)
    }
  }

  func testActiveKeySubstitutionIsDetectedBeforeAnotherAppend() throws {
    try withTrail { trail, _, keyStore in
      _ = try trail.append(input(requestID: "request-1", action: .request))
      let substituted = try keyStore.generateInactiveKey()
      try keyStore.activate(keyID: substituted.keyID)

      XCTAssertEqual(trail.verify().health, .tampered)
      XCTAssertThrowsError(try trail.append(input(requestID: "request-2", action: .operation))) {
        XCTAssertEqual(
          $0 as? AuditTrailError,
          .chainCorrupt("active audit key changed")
        )
      }
    }
  }

  func testPendingRotationRecoversAcrossActivationFailure() throws {
    try withTrail { trail, _, keyStore in
      _ = try trail.append(input(requestID: "request-1", action: .request))
      keyStore.failActivation = true
      XCTAssertThrowsError(try trail.rotateSigningKey()) {
        XCTAssertEqual($0 as? AuditTrailError, .keyRotationFailed)
      }
      XCTAssertEqual(trail.verify().health, .degraded)

      keyStore.failActivation = false
      XCTAssertTrue(try trail.recoverPendingKeyRotation())
      XCTAssertEqual(trail.verify().health, .healthy)
      let next = try trail.append(input(requestID: "request-2", action: .operation))
      XCTAssertNotEqual(next.signingKeyID, "")
    }
  }

  func testMacOSKeychainBackedSigningVerifiesAcrossStoreReopen() throws {
    let service = "dev.hostwright.audit.test.\(UUID().uuidString.lowercased())"
    let keyStore = try MacOSAuditSigningKeyStore(service: service)
    defer {
      XCTAssertNoThrow(try keyStore.removeOwnedItems())
      XCTAssertFalse(Self.keychainContains(service: service))
    }
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let trail = TamperEvidentAuditTrail(store: store, keyStore: keyStore)
    _ = try trail.append(input(requestID: "keychain-1", action: .request))
    XCTAssertEqual(trail.verify().health, .healthy)

    let reopenedKeys = try MacOSAuditSigningKeyStore(service: service)
    let reopened = TamperEvidentAuditTrail(store: store, keyStore: reopenedKeys)
    XCTAssertEqual(reopened.verify().health, .healthy)
    let rotated = try reopened.rotateSigningKey()
    let second = try reopened.append(input(requestID: "keychain-2", action: .operation))
    XCTAssertEqual(second.signingKeyID, rotated.keyID)
    XCTAssertEqual(reopened.verify().health, .healthy)
  }

  func testVerifiedBackupRestoreSynchronizesSignedAuditHead() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let service = MacOSAuditSigningKeyStore.serviceName(stateDatabasePath: store.path)
    let keyStore = try MacOSAuditSigningKeyStore(service: service)
    defer {
      XCTAssertNoThrow(try keyStore.removeOwnedItems())
      XCTAssertFalse(Self.keychainContains(service: service))
    }
    let trail = TamperEvidentAuditTrail(store: store, keyStore: keyStore)
    _ = try trail.append(input(requestID: "backup-1", action: .request))
    _ = try trail.append(input(requestID: "backup-2", action: .authorization))

    let maintenance = try StateMaintenanceService(store: store)
    let backup = try maintenance.createBackup()
    XCTAssertEqual(backup.auditHead, trail.verify().databaseHead)
    XCTAssertNotNil(backup.auditActiveKeyID)

    _ = try trail.append(input(requestID: "after-backup", action: .operation))
    XCTAssertNotEqual(trail.verify().databaseHead, backup.auditHead)
    let plan = try maintenance.restorePlan(backupID: backup.backupID)
    _ = try maintenance.restore(
      backupID: backup.backupID,
      confirmationToken: plan.confirmationToken
    )

    let restored = TamperEvidentAuditTrail(
      store: store,
      keyStore: try MacOSAuditSigningKeyStore(service: service)
    )
    let report = restored.verify()
    XCTAssertEqual(report.health, .healthy)
    XCTAssertEqual(report.databaseHead, backup.auditHead)
    XCTAssertEqual(report.externalHead, backup.auditHead)
    XCTAssertEqual(report.recordCount, 2)
  }

  private func assertTamperingDetected(
    _ mutate: (SQLiteConnection) throws -> Void
  ) throws {
    try withTrail { trail, store, _ in
      _ = try trail.append(input(requestID: "request-1", action: .request))
      _ = try trail.append(input(requestID: "request-2", action: .authorization))
      _ = try trail.append(input(requestID: "request-3", action: .operation))
      try store.withValidatedConnection { connection in
        try mutate(connection)
      }
      XCTAssertEqual(trail.verify().health, .tampered)
      XCTAssertThrowsError(try trail.exportVerified())
    }
  }

  private func withTrail(
    now: (@Sendable () -> Date)? = nil,
    _ body: (TamperEvidentAuditTrail, SQLiteStateStore, InMemoryAuditSigningKeyStore) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let keyStore = InMemoryAuditSigningKeyStore()
    let trail = TamperEvidentAuditTrail(
      store: store,
      keyStore: keyStore,
      now: now ?? { Date(timeIntervalSince1970: 1_754_166_400) }
    )
    try body(trail, store, keyStore)
  }

  private func input(requestID: String, action: AuditAction) -> AuditAppendInput {
    AuditAppendInput(
      subjectID: "owner",
      requestID: requestID,
      target: "project:00000000-0000-4000-8000-000000000001",
      action: action,
      outcome: "accepted",
      reasonCode: "accepted",
      payloadDigest: "sha256:" + String(repeating: "a", count: 64)
    )
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-audit-trail-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return root
  }

  private static func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }

  private static func keychainContains(service: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }
}

private final class LockedDate: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Date

  init(_ date: Date) {
    stored = date
  }

  var value: Date {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      stored = newValue
      lock.unlock()
    }
  }
}
