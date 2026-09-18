import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import XCTest
@testable import HostwrightState

final class ControlIdentityBootstrapTransactionTests: XCTestCase {
  private let initialTime = "2026-09-13T17:00:00Z"
  private let updateTime = "2026-09-13T17:01:00Z"

  func testFailureAfterInstallerRotationPreservesHashesSessionsAndRBAC() throws {
    try withStore { store in
      try initialize(store)
      let original = try store.controlIdentities.listIdentities()
      let owner = try XCTUnwrap(original.first { $0.codeIdentity.signingIdentifier == "dev.hostwright.cli" })
      try store.controlIdentities.persistSession(session(owner))
      let bindings = try store.rbac.listBindings()
      let rejected = code("hostwright-control", "d")
      try store.controlIdentities.revoke(ControlIdentityRevocationRecord(
        revocationID: "reject-replacement", targetKind: .codeHash,
        targetIdentifier: rejected.codeDirectoryHash, reason: "rejected replacement",
        actorSubjectID: owner.subjectID, revokedAt: updateTime
      ))
      XCTAssertThrowsError(try store.controlIdentities.applyBootstrap(ControlIdentityBootstrapRequest(
        expectedIdentities: original, userID: UInt32(geteuid()),
        installer: code("dev.hostwright.cli", "b"), companion: rejected,
        timestamp: updateTime
      )))
      XCTAssertEqual(try store.controlIdentities.listIdentities(), original)
      XCTAssertEqual(try store.rbac.listBindings(), bindings)
      XCTAssertNil(try store.controlIdentities.loadSession("original-session")?.revokedAt)
      let retirementCount = try store.withConnection(readOnly: true) { connection in
        try connection.query(
          "SELECT COUNT(*) FROM identity_revocations WHERE target_identifier = ?",
          bindings: [.text(owner.codeIdentity.codeDirectoryHash)]
        ).first?.first
      }
      XCTAssertEqual(retirementCount, "0")
      XCTAssertNoThrow(try store.controlIdentities.validateActiveSession(
        "original-session", daemonGeneration: 1, at: updateTime
      ))
    }
  }

  func testAllRotationsAndDesktopBindingCommitTogether() throws {
    try withStore { store in
      try initialize(store)
      let original = try store.controlIdentities.listIdentities()
      let owner = try XCTUnwrap(original.first { $0.codeIdentity.signingIdentifier == "dev.hostwright.cli" })
      try store.controlIdentities.persistSession(session(owner))
      try store.controlIdentities.applyBootstrap(ControlIdentityBootstrapRequest(
        expectedIdentities: original, userID: UInt32(geteuid()),
        installer: code("dev.hostwright.cli", "b"), companion: code("hostwright-control", "d"),
        desktop: code("dev.hostwright.desktop", "e"), timestamp: updateTime
      ))
      let committed = try store.controlIdentities.listIdentities()
      XCTAssertEqual(committed.count, 3)
      XCTAssertEqual(committed.first { $0.subjectID == owner.subjectID }?.generation, 2)
      XCTAssertEqual(committed.first { $0.subjectID == owner.subjectID }?.codeIdentity, code("dev.hostwright.cli", "b"))
      XCTAssertEqual(committed.first { $0.codeIdentity.signingIdentifier == "hostwright-control" }?.generation, 2)
      XCTAssertEqual(try store.controlIdentities.loadSession("original-session")?.revokedAt, updateTime)
      let desktop = try XCTUnwrap(committed.first { $0.codeIdentity.signingIdentifier == "dev.hostwright.desktop" })
      XCTAssertEqual(try store.rbac.binding(id: "desktop-operator-\(desktop.subjectID)")?.subjectID, desktop.subjectID)
    }
  }

  func testChangedExpectedSnapshotRefusesBeforeRotations() throws {
    try withStore { store in
      try initialize(store)
      let expected = try store.controlIdentities.listIdentities()
      let owner = try XCTUnwrap(expected.first { $0.codeIdentity.signingIdentifier == "dev.hostwright.cli" })
      try store.controlIdentities.declare(ControlPeerIdentityRecord(
        subjectID: "concurrent-declaration", userID: UInt32(geteuid()),
        codeIdentity: code("other-tool", "f"), declaredBySubjectID: owner.subjectID,
        declaredAt: updateTime, updatedAt: updateTime
      ))
      let current = try store.controlIdentities.listIdentities()
      XCTAssertThrowsError(try store.controlIdentities.applyBootstrap(ControlIdentityBootstrapRequest(
        expectedIdentities: expected, userID: UInt32(geteuid()),
        installer: code("dev.hostwright.cli", "b"), timestamp: updateTime
      )))
      XCTAssertEqual(try store.controlIdentities.listIdentities(), current)
    }
  }

  private func initialize(_ store: SQLiteStateStore) throws {
    try store.controlIdentities.applyBootstrap(ControlIdentityBootstrapRequest(
      expectedIdentities: [], userID: UInt32(geteuid()),
      installer: code("dev.hostwright.cli", "a"), companion: code("hostwright-control", "c"),
      timestamp: initialTime
    ))
  }

  private func code(_ identifier: String, _ hash: String) -> CodeIdentity {
    CodeIdentity(teamIdentifier: "ABCDE12345", signingIdentifier: identifier,
                 codeDirectoryHash: String(repeating: hash, count: 40), validationMode: .installedRequirement)
  }

  private func session(_ owner: ControlPeerIdentityRecord) -> ControlSessionRecord {
    ControlSessionRecord(
      sessionID: "original-session", subjectID: owner.subjectID, daemonGeneration: 1,
      serverNonceSHA256: String(repeating: "f", count: 64), socketDevice: 1, socketInode: 2,
      effectiveUID: UInt32(geteuid()), effectiveGID: UInt32(getegid()), pid: getpid(),
      pidVersion: 1, auditSessionID: 1, codeDirectoryHash: owner.codeIdentity.codeDirectoryHash,
      createdAt: initialTime, expiresAt: "2026-09-13T18:00:00Z", updatedAt: initialTime
    )
  }

  private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-bootstrap-transaction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try MigrationRunner().apply(to: store)
    try body(store)
  }
}
